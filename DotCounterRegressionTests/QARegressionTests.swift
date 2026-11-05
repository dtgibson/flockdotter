import XCTest
import SwiftUI
import UIKit
import DotCounterCore
@testable import DotCounter

@MainActor final class QARegressionTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        continueAfterFailure = false
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-QA-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func workspace() async throws -> Workspace {
        let source = directory.appendingPathComponent("fixture.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { context in
            UIColor.systemGray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }
        try XCTUnwrap(image.pngData()).write(to: source)
        let workspace = Workspace(qaDirectory: directory.appendingPathComponent("recovery"))
        await workspace.startup()
        await workspace.preparePhoto(source)
        XCTAssertNotNil(workspace.snapshot)
        workspace.tap(CGPoint(x: 0.5, y: 0.5), hit: nil)
        XCTAssertTrue(workspace.dirty)
        return workspace
    }
    private func request(_ kind: String, source: URL? = nil) -> ExportSaveState.Request {
        .init(source: source ?? directory.appendingPathComponent("source"), filename: "output-\(kind)", kind: kind)
    }
    func testProviderFailureAndCancellationForEachOutputPreserveIdentityAndBaseline() async throws {
        let workspace = try await workspace()
        let baseline = workspace.snapshot?.baselineDigest
        let document = try XCTUnwrap(workspace.document)
        for kind in ["PNG", "JSON", "Original Photo"] {
            let state = ExportSaveState()
            state.status = ["PNG": "PNG saved", "JSON": "JSON saved"]
            let successes = state.status
            state.begin(request(kind))
            XCTAssertNil(state.receiveFolderResult(.failure(NSError(domain: "QAProvider", code: 503, userInfo: [NSLocalizedDescriptionKey: "Provider unavailable"]))))
            XCTAssertNil(state.pending)
            XCTAssertEqual(state.retry?.kind, kind)
            XCTAssertTrue(try XCTUnwrap(state.error).contains(kind == "Original Photo" ? "original photo copy failed" : "\(kind) could not be saved"))
            XCTAssertTrue(try XCTUnwrap(state.error).contains("Provider unavailable"))
            XCTAssertEqual(state.status, successes)
            XCTAssertEqual(workspace.snapshot?.baselineDigest, baseline)
            XCTAssertTrue(workspace.dirty)
            // Explicit retry retains the same source/filename/output identity.
            state.begin(try XCTUnwrap(state.retry))
            XCTAssertNil(state.receiveFolderResult(.failure(CocoaError(.userCancelled))))
            XCTAssertNil(state.error)
            XCTAssertNil(state.retry)
            XCTAssertNil(state.pending)
            XCTAssertEqual(state.status, successes)
            XCTAssertEqual(workspace.document?.contentDigest, document.contentDigest)
            XCTAssertEqual(workspace.snapshot?.baselineDigest, baseline)
        }
        await workspace.flush()
    }
    func testCopySuccessFailureAndRetryKeepSeparateStatusesAndOnlySuccessfulJSONChangesBaseline() async throws {
        let workspace = try await workspace()
        let document = try XCTUnwrap(workspace.document)
        let workspaceID = try XCTUnwrap(workspace.snapshot?.workspaceID)
        let baseline = workspace.snapshot?.baselineDigest
        let state = ExportSaveState()
        let json = directory.appendingPathComponent("markers.json")
        try document.encoded().write(to: json)
        let destinations = directory.appendingPathComponent("outputs", isDirectory: true)
        try FileManager.default.createDirectory(at: destinations, withIntermediateDirectories: true)
        // A native destination result is not itself a successful export.
        state.begin(request("JSON", source: json))
        let selected = try XCTUnwrap(state.receiveFolderResult(.success([destinations])))
        XCTAssertEqual(workspace.snapshot?.baselineDigest, baseline)
        // Exclusive-copy failure must leave baseline dirty and offer JSON retry.
        try Data("occupied".utf8).write(to: selected.url)
        await state.save(selected, workspace: workspace, document: document, workspaceID: workspaceID)
        XCTAssertNil(state.status["JSON"])
        XCTAssertEqual(state.retry?.kind, "JSON")
        XCTAssertEqual(workspace.snapshot?.baselineDigest, baseline)
        XCTAssertEqual(try Data(contentsOf: selected.url), Data("occupied".utf8))
        try FileManager.default.removeItem(at: selected.url)
        state.begin(try XCTUnwrap(state.retry))
        let retried = try XCTUnwrap(state.receiveFolderResult(.success([destinations])))
        await state.save(retried, workspace: workspace, document: document, workspaceID: workspaceID)
        XCTAssertEqual(state.status["JSON"], "JSON saved")
        XCTAssertFalse(workspace.dirty)
        XCTAssertEqual(try CountDocument.decode(Data(contentsOf: retried.url)).contentDigest, document.contentDigest)
        state.begin(request("Original Photo"))
        XCTAssertNil(state.receiveFolderResult(.failure(CocoaError(.fileWriteNoPermission))))
        XCTAssertEqual(state.status["JSON"], "JSON saved")
        XCTAssertNil(state.status["Original Photo"])
        XCTAssertTrue(try XCTUnwrap(state.error).hasPrefix("JSON was saved. The original photo copy failed."))
        // The original copy uses the same destination/copy path and preserves bytes.
        let source = try XCTUnwrap(workspace.candidate?.sourceURL)
        state.begin(request("Original Photo", source: source))
        let original = try XCTUnwrap(state.receiveFolderResult(.success([destinations])))
        await state.save(original, workspace: workspace, document: document, workspaceID: workspaceID)
        XCTAssertEqual(try Data(contentsOf: original.url), try Data(contentsOf: source))
        XCTAssertEqual(state.status["JSON"], "JSON saved")
        XCTAssertEqual(state.status["Original Photo"], "Original Photo saved")
        XCTAssertNil(state.error)
        await workspace.flush()
    }
    private func descendants<T: UIView>(_ root: UIView, of type: T.Type) -> [T] {
        (root as? T).map { [$0] } ?? root.subviews.flatMap { descendants($0, of: type) }
    }
    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }
    func testModeFontGrowsAndUpdatesLiveWithNativeTraits() async throws {
        let workspace = try await workspace()
        let host = UIHostingController(rootView: NativeModePicker(workspace: workspace).fixedSize())
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host; window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        host.traitOverrides.preferredContentSizeCategory = .large
        try await settle()
        let picker = try XCTUnwrap(descendants(host.view, of: ModeSegmentedControl.self).first)
        let ordinary = picker.titleFont.pointSize
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await settle()
        let enlarged = picker.titleFont.pointSize
        XCTAssertGreaterThan(enlarged, ordinary * 1.5)
        XCTAssertGreaterThan(picker.bounds.height, 44)
        XCTAssertGreaterThanOrEqual(picker.bounds.height, picker.titleFont.lineHeight + 19)
        XCTAssertLessThanOrEqual(picker.bounds.width, 288, "Enlarged mode titles fit a 320pt compact workspace with 16pt margins")
        for state: UIControl.State in [.normal, .selected] {
            XCTAssertEqual((picker.titleTextAttributes(for: state)?[.font] as? UIFont)?.pointSize, enlarged)
            XCTAssertNotNil(picker.titleTextAttributes(for: state)?[.foregroundColor])
        }
        host.traitOverrides.preferredContentSizeCategory = .large
        try await settle()
        XCTAssertEqual(picker.titleFont.pointSize, ordinary, accuracy: 0.01)
        XCTAssertEqual(picker.bounds.height, 44, accuracy: 1)
        let evidence = "ordinaryFont=\(ordinary), accessibilityXXXLFont=\(enlarged), compactWidth=320; native large→AX5→large trait change passed"
        let attachment = XCTAttachment(string: evidence); attachment.lifetime = .keepAlways; add(attachment)
        await workspace.flush()
    }
    func testCompactAccessibilityLayoutKeepsCanvasAndScrollableControlRegionsSeparate() async throws {
        let workspace = try await workspace()
        workspace.mode = .edit; workspace.selectedID = workspace.markers.first?.id
        let host = UIHostingController(rootView: WorkspaceView(workspace: workspace))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 568)
        host.view.frame = window.bounds; host.view.layoutIfNeeded()
        defer { window.isHidden = true }
        try await settle()
        XCTAssertEqual(workspace.total, 1)
        XCTAssertEqual(workspace.selectedLabel, 1)
        XCTAssertFalse(workspace.recoveryStale)
        XCTAssertEqual(host.view.bounds.width, 320, accuracy: 1)
        let picker = try XCTUnwrap(descendants(host.view, of: ModeSegmentedControl.self).first)
        let canvas = try XCTUnwrap(descendants(host.view, of: TouchCanvas.self).first)
        let scrolls = descendants(host.view, of: UIScrollView.self)
        XCTAssertEqual(scrolls.count, 2)
        XCTAssertGreaterThanOrEqual(canvas.bounds.height, 100)
        for scroll in scrolls {
            let frame = scroll.convert(scroll.bounds, to: host.view)
            let canvasFrame = canvas.convert(canvas.bounds, to: host.view)
            XCTAssertLessThanOrEqual(frame.intersection(canvasFrame).height, 1)
            XCTAssertLessThanOrEqual(frame.maxX, host.view.bounds.maxX + 1)
            XCTAssertGreaterThanOrEqual(frame.minX, -1)
        }
        let top = try XCTUnwrap(scrolls.min(by: { $0.frame.minY < $1.frame.minY }))
        top.scrollRectToVisible(picker.convert(picker.bounds, to: top), animated: false)
        try await settle()
        XCTAssertTrue(top.bounds.intersects(picker.convert(picker.bounds, to: top)), "Mode is reachable by scrolling its controls, without scrolling the canvas")
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "320x568 AX5 selected edit layout"; attachment.lifetime = .keepAlways; add(attachment)
        await workspace.flush()
    }
    func testNativeTotalFontUpdatesAndDisplaysGroupedValue() async throws {
        let host = UIHostingController(rootView: NativeTotalLabel(value: 1000, revision: 1, compact: true))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.traitOverrides.preferredContentSizeCategory = .large
        try await settle()
        let total = try XCTUnwrap(descendants(host.view, of: NativeTotalText.self).first)
        XCTAssertEqual(total.attributedText?.string, 1000.formatted())
        let ordinary = try XCTUnwrap(total.font).pointSize
        XCTAssertEqual(ordinary, 42, accuracy: 0.1)
        host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge
        try await settle()
        XCTAssertGreaterThan(try XCTUnwrap(total.font).pointSize, ordinary)
        XCTAssertEqual(total.minimumScaleFactor, 0.5)
        host.traitOverrides.preferredContentSizeCategory = .large
        try await settle()
        XCTAssertEqual(try XCTUnwrap(total.font).pointSize, ordinary, accuracy: 0.1)
    }
    func testActiveWarmLocal24MPFileOpeningWith1000Markers() async throws {
        let workspace = Workspace(qaDirectory: directory.appendingPathComponent("warm-recovery"))
        await workspace.startup()
        let source = try await NativeQAFixture.makeImage()
        await workspace.preparePhoto(source, filename: "Warm-24MP.jpg")
        let current = try XCTUnwrap(workspace.snapshot)
        let candidate = try XCTUnwrap(workspace.candidate)
        let document = CountDocument(image: candidate.identity, markers: NativeQAFixture.markers)
        workspace.history = MarkerHistory(markers: document.markers)
        workspace.snapshot = RecoverySnapshot(workspaceID: current.workspaceID, revision: current.revision + 1, sourceToken: current.sourceToken, image: current.image, markers: document.markers, baselineDigest: document.contentDigest)
        await workspace.flush()
        let host = UIHostingController(rootView: WorkspaceView(workspace: workspace))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = host
        let recorder = NativeQARecorder.shared
        let output = directory.appendingPathComponent("active-warm-file-open.json")
        recorder.activateHostedTest(output: output)
        window.makeKeyAndVisible()
        defer { recorder.deactivateHostedTest(); window.isHidden = true }
        try await settle()
        // Same state as returning from Choose Original Photo in an active app:
        // the decoded count is paired, the photo picker has dismissed, and its
        // selected local URL enters the production preparePhoto path.
        workspace.pairing = document; workspace.showPairing = false
        let before = recorder.activeWarmFileOpens.count
        await workspace.preparePhoto(source, filename: "Warm-24MP.jpg")
        for _ in 0..<30 where recorder.activeWarmFileOpens.count == before { try await settle() }
        XCTAssertEqual(workspace.total, 1000)
        let evidence = try XCTUnwrap(recorder.activeWarmFileOpens.last)
        XCTAssertEqual(evidence["total"] as? Int, 1000)
        XCTAssertEqual(evidence["imagePixels"] as? [Int], [6000, 4000])
        let milliseconds = try XCTUnwrap(evidence["preparePhotoToOpportunityMs"] as? Double)
        XCTAssertLessThan(milliseconds, 2000, "Active warm local-file opening, including native total/canvas draw and presentation opportunity")
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        let proof = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); proof.name = "Active warm 24MP file opening native evidence"; proof.lifetime = .keepAlways; add(proof)
        print("ACTIVE_WARM_FILE_OPEN_MS=\(milliseconds)")
        await workspace.flush()
    }

    func testAdaptiveCanvasNavigationBlankAreaAndResizeNeverCommitAnEdit() async throws {
        let w = try await workspace()
        let engine = CanvasEngine(w)
        let size = CGSize(width: 400, height: 700)
        let clear = CGRect(x: 12, y: 100, width: 376, height: 480)
        engine.update(size: size, workingRect: clear)
        engine.zoom(3, at: CGPoint(x: clear.midX, y: clear.midY))
        let before = try XCTUnwrap(w.document)
        let revision = w.snapshot?.revision
        // A Count-mode drag starting over an existing marker is navigation.
        let marker = engine.viewport.screenPoint(x: 0.5, y: 0.5)
        engine.begin(marker, radius: 22)
        engine.drag(CGPoint(x: marker.x + 90, y: marker.y + 60), threshold: 8)
        engine.end(CGPoint(x: marker.x + 90, y: marker.y + 60), radius: 22)
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot?.revision, revision)
        // Manually pan the top-left photo corner into the clear center.
        let corner = engine.viewport.screenPoint(x: 0, y: 0)
        engine.pan(CGSize(width: clear.midX - corner.x, height: clear.midY - corner.y))
        let blank = CGPoint(x: clear.midX - 20, y: clear.midY - 20)
        engine.begin(blank, radius: 22); engine.end(blank, radius: 22)
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot?.revision, revision)
        let scale = engine.viewport.scale
        // Invalidate a real pending edit when geometry changes beneath the finger.
        w.mode = .edit
        let center = engine.viewport.screenPoint(x: 0.5, y: 0.5)
        engine.begin(center, radius: 22)
        engine.drag(CGPoint(x: center.x + 30, y: center.y + 30), threshold: 8)
        engine.update(size: CGSize(width: 700, height: 400), workingRect: CGRect(x: 12, y: 80, width: 676, height: 260))
        engine.end(CGPoint(x: center.x + 30, y: center.y + 30), radius: 22)
        XCTAssertEqual(w.document, before); XCTAssertEqual(w.snapshot?.revision, revision)
        XCTAssertEqual(engine.viewport.scale, scale, accuracy: 1e-12)
        XCTAssertNil(engine.gestureEpoch)
        w.fitCommand += 1; engine.update(size: engine.viewport.canvasSize, workingRect: engine.viewport.workingRect)
        XCTAssertEqual(engine.viewport.zoomFactor, 1, accuracy: 1e-12)
        XCTAssertEqual(w.document, before)
    }

    /// Stage 4: live native view geometry, retained engine and selected/review
    /// identity across representative intermediate and very short windows.
    /// Hosted resize evidence is separate from production touch-input evidence.
    func testQAAdaptiveSelectedReviewLiveResizeAndShortAccessibility() async throws {
        let w = try await workspace()
        w.mode = .edit; w.selectedID = w.markers.first?.id
        let before = try XCTUnwrap(w.document), selected = w.selectedID
        let snapshot = try XCTUnwrap(w.snapshot), candidate = try XCTUnwrap(w.candidate)
        let key = BirdDetectionKey(workspace: snapshot.workspaceID, source: snapshot.sourceToken, generation: w.birdGeneration, image: candidate.identity, revision: snapshot.revision)
        w.birdKey = key
        var review = try BirdReview(key: key, suggestions: [BirdSuggestion(id: "qa-a", x: 0.05, y: 0.05, width: 0.02, height: 0.02, score: 0.9), BirdSuggestion(id: "qa-b", x: 0.95, y: 0.95, width: 0.02, height: 0.02, score: 0.8)], eligible: true)
        XCTAssertTrue(review.decide(.accepted, target: "qa-a", epoch: review.epoch))
        w.birdReview = review
        let decisions = review.decisions, epoch = review.epoch
        let host = UIHostingController(rootView: WorkspaceView(workspace: w))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var retained: CanvasEngine?
        for size in [CGSize(width: 700, height: 700), CGSize(width: 520, height: 420), CGSize(width: 520, height: 500), CGSize(width: 320, height: 260)] {
            if size.height == 260 { host.traitOverrides.preferredContentSizeCategory = .accessibilityExtraExtraExtraLarge }
            window.frame = CGRect(origin: .zero, size: size); host.view.frame = window.bounds; host.view.layoutIfNeeded()
            try await settle(); host.view.layoutIfNeeded(); try await settle()
            let canvas = try XCTUnwrap(descendants(host.view, of: TouchCanvas.self).first)
            if let retained { XCTAssertTrue(canvas.engine === retained, "A layout branch must retain the canvas engine") }
            retained = canvas.engine
            XCTAssertGreaterThanOrEqual(canvas.bounds.height, 100)
            XCTAssertEqual(w.document, before); XCTAssertEqual(w.selectedID, selected); XCTAssertEqual(w.mode, .edit)
            XCTAssertEqual(w.birdReview?.decisions, decisions); XCTAssertEqual(w.birdReview?.epoch, epoch)
            let modes = try XCTUnwrap(descendants(host.view, of: ModeSegmentedControl.self).first)
            XCTAssertGreaterThanOrEqual(modes.bounds.height, 44)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let a = XCTAttachment(image: image); a.name = "QA native selected review \(Int(size.width))x\(Int(size.height))"; a.lifetime = .keepAlways; add(a)
            let text = XCTAttachment(string: "window=\(window.bounds) canvas=\(canvas.convert(canvas.bounds,to:host.view)) working=\(canvas.engine.viewport.workingRect) scale=\(canvas.engine.viewport.scale) selected=\(String(describing: selected)) decisions=\(decisions) epoch=\(epoch)"); text.lifetime = .keepAlways; add(text)
            if size.width == 520 {
                let scrollFrames = descendants(host.view, of: UIScrollView.self).filter { !$0.isHidden && $0.alpha > 0 }.map { $0.convert($0.bounds, to: host.view).intersection(host.view.bounds) }
                let proof = XCTAttachment(string: "Visible scroll-host intersections at 520x420: \(scrollFrames)"); proof.name = "QA adaptive supplement hit containment"; proof.lifetime = .keepAlways; add(proof)
                XCTAssertTrue(scrollFrames.contains { $0.height >= 44 && $0.width >= 44 }, "Selected/review controls need a visible scroll host that can contain a 44pt target; got \(scrollFrames)")
            }
            // Delta raster/hit proof: public in-process accessibility exposes
            // UIKit views but not SwiftUI virtual buttons. Capture the real
            // scroller at bounded offsets instead of fabricating AX geometry.
            if size.width != 700 {
                let scroll = try XCTUnwrap(descendants(host.view, of: UIScrollView.self).filter { !$0.isHidden && $0.alpha > 0 }.last)
                let clip = scroll.convert(scroll.bounds.inset(by: scroll.adjustedContentInset), to: host.view).intersection(host.view.bounds)
                XCTAssertGreaterThanOrEqual(clip.height, 44)
                let top = -scroll.adjustedContentInset.top
                let end = max(top, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
                let step = max(20, min(36, clip.height / 3))
                var offsets = stride(from: top, to: end, by: step).map { $0 }; offsets.append(end)
                XCTAssertLessThanOrEqual(offsets.count, 48, "Bounded target evidence sweep")
                for (index, offset) in offsets.enumerated() {
                    scroll.setContentOffset(CGPoint(x: 0, y: offset), animated: false); try await settle()
                    let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
                    let name = "QA delta \(Int(size.width))x\(Int(size.height)) scroll \(index)"
                    let capture = XCTAttachment(image: image); capture.name = name; capture.lifetime = .keepAlways; add(capture)
                    // Grid is actual UIKit hit routing. 1=the native photo view;
                    // 0=another view. Coordinates/clip are in native points.
                    var grid: [String] = []
                    for y in stride(from: clip.minY + 4, to: clip.maxY, by: 8) {
                        grid.append(stride(from: clip.minX + 4, to: clip.maxX, by: 8).map { x in host.view.hitTest(CGPoint(x:x,y:y),with:nil) === canvas ? "1":"0" }.joined())
                    }
                    let proof = XCTAttachment(string: "size=\(size) offset=\(scroll.contentOffset) content=\(scroll.contentSize) adjustedInsets=\(scroll.adjustedContentInset) clip=\(clip) gridOrigin=(\(clip.minX+4),\(clip.minY+4)) step=8\n" + grid.joined(separator:"\n")); proof.name = name + " hit routing"; proof.lifetime = .keepAlways; add(proof)
                    XCTAssertEqual(w.document, before); XCTAssertEqual(w.selectedID, selected); XCTAssertEqual(w.mode, .edit)
                    XCTAssertEqual(w.birdReview?.decisions, decisions); XCTAssertEqual(w.birdReview?.epoch, epoch)
                }
                if canvas.isDescendant(of: scroll) {
                    let canvasRect = canvas.convert(canvas.bounds, to: scroll)
                    scroll.scrollRectToVisible(canvasRect, animated: false); try await settle()
                    let visibleCanvas = canvas.convert(canvas.bounds, to: host.view).intersection(clip)
                    XCTAssertGreaterThan(visibleCanvas.height, 40)
                    XCTAssertTrue(host.view.hitTest(CGPoint(x: visibleCanvas.midX, y: visibleCanvas.midY), with: nil) === canvas, "Scrolled-out actions must not intercept the canvas")
                } else {
                    // In floated layout the supplement and canvas are siblings;
                    // its viewport must not be used as the canvas clip region.
                    let clear = canvas.engine.viewport.workingRect
                    let point = canvas.convert(CGPoint(x: clear.midX, y: clear.midY), to: host.view)
                    XCTAssertTrue(host.view.hitTest(point, with: nil) === canvas, "Floated scrolled-out actions must not intercept the clear canvas")
                }
            }
        }
        await w.flush()
    }
}

@MainActor final class SecurityRegressionTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-Security-Hosted-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func workspace() async throws -> Workspace {
        let input = root.appendingPathComponent("source.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { context in
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
        }
        try XCTUnwrap(image.pngData()).write(to: input)
        let workspace = Workspace(qaDirectory: root.appendingPathComponent("recovery"))
        await workspace.startup(); await workspace.preparePhoto(input)
        workspace.tap(CGPoint(x: 0.3, y: 0.4), hit: nil); await workspace.flush()
        return workspace
    }
    func testPhotosOwnedInputRetiresAfterSuccessRejectionAndCancelledOpening() async throws {
        let workspace = try await workspace()
        let current = try XCTUnwrap(workspace.document), id = workspace.snapshot?.workspaceID
        let source = root.appendingPathComponent("source.png")
        var photo: PickedPhoto? = try PickedPhoto.importFile(source)
        let firstDirectory = try XCTUnwrap(photo).owner.url
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(photo).url), try Data(contentsOf: source))
        // Prepared candidate stays isolated until the replacement choice.
        await workspace.preparePhoto(try XCTUnwrap(photo).url)
        XCTAssertTrue(workspace.showReplacement)
        workspace.cancelReplacement(); photo = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: firstDirectory.path))
        XCTAssertEqual(workspace.document, current)
        let invalid = root.appendingPathComponent("invalid.jpg"); try Data([3, 4, 5]).write(to: invalid)
        photo = try PickedPhoto.importFile(invalid)
        let invalidDirectory = try XCTUnwrap(photo).owner.url
        await workspace.preparePhoto(try XCTUnwrap(photo).url)
        photo = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: invalidDirectory.path))
        XCTAssertEqual(workspace.document, current); XCTAssertEqual(workspace.snapshot?.workspaceID, id)
        photo = try PickedPhoto.importFile(source)
        let cancelledDirectory = try XCTUnwrap(photo).owner.url, url = try XCTUnwrap(photo).url
        let opening = Task { await workspace.preparePhoto(url) }
        while !workspace.busy { await Task.yield() }
        workspace.cancelOpening(); await opening.value; photo = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelledDirectory.path))
        XCTAssertEqual(workspace.document, current); XCTAssertEqual(workspace.snapshot?.workspaceID, id)
        XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: XCTUnwrap(workspace.candidate).sourceURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        await workspace.flush()
    }
    func testOversizedJSONPreservesInstalledCountAndRecoveryBytes() async throws {
        let workspace = try await workspace()
        let document = workspace.document, id = workspace.snapshot?.workspaceID
        let manifest = root.appendingPathComponent("recovery/current.json")
        let before = try Data(contentsOf: manifest)
        let source = root.appendingPathComponent("oversized.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source); try handle.truncate(atOffset: 33 * 1024 * 1024); try handle.close()
        await workspace.prepareJSON(source)
        XCTAssertNotNil(workspace.error); XCTAssertNil(workspace.pairing)
        XCTAssertEqual(workspace.document, document); XCTAssertEqual(workspace.snapshot?.workspaceID, id)
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }
    func testGeneratedFilesRemainReadableAcrossFailureRetryCancelUntilClose() throws {
        let state = ExportSaveState()
        var owner: TransientDirectory? = try state.resources()
        let directory = try XCTUnwrap(owner).url, source = directory.appendingPathComponent("markers.json")
        try Data("unchanged retry data".utf8).write(to: source)
        state.begin(.init(source: source, filename: "markers.json", kind: "JSON", owner: owner)); owner = nil
        XCTAssertNil(state.receiveFolderResult(.failure(CocoaError(.fileWriteNoPermission))))
        XCTAssertNotNil(state.retry)
        try TransientDirectory.removeOrphans()
        XCTAssertEqual(try Data(contentsOf: source), Data("unchanged retry data".utf8))
        state.begin(try XCTUnwrap(state.retry))
        XCTAssertNil(state.receiveFolderResult(.failure(CocoaError(.userCancelled))))
        XCTAssertNil(state.error); XCTAssertNil(state.retry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        state.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertThrowsError(try state.resources())
    }
    func testClosingDuringActualCopyRetainsReaderAndDestinationWithoutLateBaselineMutation() async throws {
        let workspace = try await workspace()
        let document = try XCTUnwrap(workspace.document), id = try XCTUnwrap(workspace.snapshot?.workspaceID)
        let baseline = workspace.snapshot?.baselineDigest
        let state = ExportSaveState()
        var owner: TransientDirectory? = try state.resources()
        let directory = try XCTUnwrap(owner).url, source = directory.appendingPathComponent("markers.json")
        let bytes = try document.encoded(); try bytes.write(to: source)
        var destination: ExportSaveState.Destination? = .init(request: .init(source: source, filename: "saved.json", kind: "JSON", owner: owner), url: root.appendingPathComponent("saved.json"), scopedFolder: nil)
        owner = nil
        var copy: Task<Void, Never>? = Task { @MainActor [selected = destination!] in
            await state.save(selected, workspace: workspace, document: document, workspaceID: id)
        }
        while !state.saving { await Task.yield() }
        state.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await copy?.value
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("saved.json")), bytes)
        XCTAssertEqual(workspace.snapshot?.baselineDigest, baseline); XCTAssertTrue(workspace.dirty)
        XCTAssertNil(state.status["JSON"]); XCTAssertNil(state.retry)
        destination = nil; copy = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        await workspace.flush()
    }
    func testRenderAndPreviewReaderSurvivesSessionCloseThenRetiresPNG() async throws {
        let workspace = try await workspace()
        let state = ExportSaveState()
        var reader: TransientDirectory? = try state.resources()
        let directory = try XCTUnwrap(reader).url
        state.close()
        let source = try XCTUnwrap(workspace.candidate).sourceURL, document = try XCTUnwrap(workspace.document)
        let png = try await ImageService.renderPNG(sourceURL: source, document: document, directory: directory)
        _ = try await ImageService.preview(sourceURL: png, maxPixel: 80)
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
        XCTAssertNil(state.error)
        reader = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        await workspace.flush()
    }
}

@MainActor final class WorkspaceClearTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-Clear-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("original.png"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func workspace(fault: (@Sendable (RecoveryFaultPoint) throws -> Void)? = nil) async -> Workspace {
        let w = Workspace(qaDirectory: root.appendingPathComponent("Recovery"), fault: fault)
        await w.startup(); await w.preparePhoto(root.appendingPathComponent("original.png"))
        return w
    }
    private func target(_ w: Workspace) throws -> Workspace.ClearTarget { w.requestClear(); return try XCTUnwrap(w.clearTarget) }
    func testConfirmationCancelTargetChangeFullResetRelaunchAndReuse() async throws {
        let w = await workspace()
        let before = w.lifecycleEpoch, snapshot = w.snapshot, bytes = try Data(contentsOf: root.appendingPathComponent("Recovery/current.json"))
        XCTAssertTrue(w.canClear, "zero-marker photo always offers Clear")
        let obsolete = try target(w)
        w.clearTarget = nil // Native cancel/dismiss only closes the confirmation.
        XCTAssertEqual(w.lifecycleEpoch, before); XCTAssertEqual(w.snapshot, snapshot)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Recovery/current.json")), bytes)
        w.tap(CGPoint(x: 0.2, y: 0.3), hit: nil); await w.flush()
        await w.confirmClear(obsolete)
        XCTAssertNotNil(w.clearTarget, "changed count requires a fresh confirmation")
        XCTAssertEqual(w.total, 1); XCTAssertEqual(w.lifecycleEpoch, before)
        w.selectedID = w.markers[0].id; w.mode = .edit
        let doc = try XCTUnwrap(w.document), snap = try XCTUnwrap(w.snapshot)
        w.recordJSONExport(doc.contentDigest, workspace: snap.workspaceID)
        await w.flush()
        XCTAssertFalse(w.dirty); XCTAssertTrue(w.canClear, "exported baseline also always confirms")
        let key = BirdDetectionKey(workspace: snap.workspaceID, source: snap.sourceToken, generation: w.birdGeneration, image: snap.image, revision: try XCTUnwrap(w.snapshot).revision)
        w.birdKey = key
        w.birdReview = try BirdReview(key: key, suggestions: [BirdSuggestion(id: "synthetic", x: 0.4, y: 0.5, width: 0.1, height: 0.1, score: 0.8)], eligible: true)
        w.birdReview?.skipAll(); w.birdReview?.addDraft(x: 0.7, y: 0.8)
        let held = try await w.acquireSourceLease(snap.sourceToken)
        let loadedBytes = try Data(contentsOf: held)
        await w.confirmClear(try target(w))
        XCTAssertFalse(w.clearing); XCTAssertFalse(w.clearFailed); XCTAssertNil(w.candidate); XCTAssertNil(w.snapshot)
        XCTAssertEqual(w.total, 0); XCTAssertNil(w.selectedID); XCTAssertFalse(w.history.canUndo); XCTAssertFalse(w.history.canRedo)
        XCTAssertNil(w.birdReview); XCTAssertNil(w.birdKey); XCTAssertNil(w.pairing); XCTAssertNil(w.pending)
        w.undo(); w.redo(); await w.flush(); XCTAssertEqual(w.total, 0)
        XCTAssertEqual(try Data(contentsOf: held), loadedBytes)
        await w.releaseSourceLease(snap.sourceToken)
        XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
        let reopened = Workspace(qaDirectory: root.appendingPathComponent("Recovery")); await reopened.startup(); await reopened.flush()
        XCTAssertNil(reopened.candidate); XCTAssertEqual(reopened.total, 0)
        await w.preparePhoto(root.appendingPathComponent("original.png")); w.tap(CGPoint(x: 0.1, y: 0.1), hit: nil); await w.flush()
        XCTAssertEqual(w.total, 1); XCTAssertFalse(w.recoveryStale)
    }
    final class ClearGate: @unchecked Sendable {
        private let lock = NSLock(), release = DispatchSemaphore(value: 0)
        private var armed = true, reached = false
        var entered: Bool { lock.lock(); defer { lock.unlock() }; return reached }
        func finish() { lock.lock(); armed = false; lock.unlock(); release.signal() }
        func check(_ point: RecoveryFaultPoint) throws {
            lock.lock(); let shouldWait = armed && point == .afterClearRemoval
            if shouldWait { reached = true }; lock.unlock()
            if shouldWait { release.wait(); throw RecoveryError.injected(point) }
        }
    }
    func testUncertainClearBlocksCommandsRetainsCountAndRejectsOldIngressAfterFailure() async throws {
        let gate = ClearGate(), w = await workspace(fault: { try gate.check($0) })
        let host = UIHostingController(rootView: WorkspaceView(workspace: w))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func capture(_ name: String) {
            host.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        w.tap(CGPoint(x: 0.2, y: 0.3), hit: nil); await w.flush()
        w.selectedID = w.markers[0].id; w.mode = .edit
        let oldEpoch = w.lifecycleEpoch, doc = try XCTUnwrap(w.document), selected = w.selectedID
        let oldSnapshot = try XCTUnwrap(w.snapshot), engine = CanvasEngine(w)
        engine.update(size: CGSize(width: 393, height: 600)); engine.begin(engine.viewport.screenPoint(x: 0.2, y: 0.3), radius: 20)
        let confirmation = try target(w)
        // Model the native alert button's dismissal before directly invoking its action.
        w.clearTarget = nil
        try await Task.sleep(for: .milliseconds(350))
        let attempt = Task { await w.confirmClear(confirmation) }
        for _ in 0..<500 where !gate.entered { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gate.entered); XCTAssertTrue(w.clearing); XCTAssertEqual(w.document, doc)
        try await Task.sleep(for: .milliseconds(150)); capture("Native hosted clear progress with held filesystem operation")
        w.tap(CGPoint(x: 0.5, y: 0.5), hit: nil); w.remove(); w.undo(); w.redo(); w.renumber(.leftToRight)
        w.deselect(); w.changeMode(.count); w.showExport(); w.openPhotoFiles(); w.openCountFile(); w.startBirdDetection()
        XCTAssertEqual(w.document, doc); XCTAssertEqual(w.selectedID, selected); XCTAssertEqual(w.mode, .edit)
        XCTAssertFalse(w.exportShown); XCTAssertFalse(w.openFiles); XCTAssertFalse(w.openJSON); XCTAssertFalse(w.canClear)
        await w.confirmClear(confirmation) // Duplicate must settle immediately.
        let waitingFlush = Task { await w.flush() }
        gate.finish(); await attempt.value; await waitingFlush.value
        XCTAssertTrue(w.clearFailed); XCTAssertTrue(w.recoveryStale); XCTAssertEqual(w.document, doc)
        try await Task.sleep(for: .milliseconds(150)); capture("Native hosted retained count after uncertain clear")
        XCTAssertEqual(w.selectedID, selected); XCTAssertTrue(w.history.canUndo)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(w.candidate).sourceURL), try Data(contentsOf: root.appendingPathComponent("original.png")))
        await w.preparePhoto(root.appendingPathComponent("missing.png"), requestEpoch: oldEpoch)
        await w.prepareJSON(root.appendingPathComponent("missing.json"), requestEpoch: oldEpoch)
        await w.useCurrentPhoto(requestEpoch: oldEpoch); await w.replace(requestEpoch: oldEpoch)
        w.recordJSONExport("invalid", workspace: oldSnapshot.workspaceID, requestEpoch: oldEpoch)
        engine.end(CGPoint(x: 200, y: 200), radius: 20)
        XCTAssertEqual(w.document, doc); XCTAssertEqual(w.snapshot, oldSnapshot); XCTAssertNil(w.error)
        XCTAssertNil(w.pending); XCTAssertNil(w.pairing); XCTAssertFalse(w.showPairing); XCTAssertFalse(w.showReplacement)
        // A captured export request cannot update its baseline/status after failed clear,
        // even though the visible workspace UUID was retained.
        let state = ExportSaveState(), output = root.appendingPathComponent("stale-output.json")
        let destination = ExportSaveState.Destination(request: .init(source: root.appendingPathComponent("missing.json"), filename: "stale-output.json", kind: "JSON"), url: output, scopedFolder: nil)
        await state.save(destination, workspace: w, document: doc, workspaceID: oldSnapshot.workspaceID, requestEpoch: oldEpoch)
        XCTAssertNil(state.error); XCTAssertTrue(state.status.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        await w.confirmClear(try target(w)); XCTAssertNil(w.candidate); XCTAssertFalse(w.clearFailed)
        await w.flush()
        let reopened = Workspace(qaDirectory: root.appendingPathComponent("Recovery")); await reopened.startup(); XCTAssertNil(reopened.candidate)
    }
    func testNewWorkspaceRejectsOldPhotoJSONPairingExportAndGestureCallbacks() async throws {
        let w = await workspace(), oldEpoch = w.lifecycleEpoch
        let oldDocument = try XCTUnwrap(w.document), oldID = try XCTUnwrap(w.snapshot?.workspaceID)
        await w.confirmClear(try target(w))
        await w.preparePhoto(root.appendingPathComponent("original.png")); w.tap(CGPoint(x: 0.4, y: 0.5), hit: nil); await w.flush()
        let current = w.snapshot
        await w.preparePhoto(root.appendingPathComponent("original.png"), requestEpoch: oldEpoch)
        await w.prepareJSON(root.appendingPathComponent("missing.json"), requestEpoch: oldEpoch)
        await w.replace(requestEpoch: oldEpoch); await w.useCurrentPhoto(requestEpoch: oldEpoch)
        w.recordJSONExport(oldDocument.contentDigest, workspace: oldID, requestEpoch: oldEpoch)
        XCTAssertEqual(w.snapshot, current); XCTAssertEqual(w.total, 1); XCTAssertNil(w.pending); XCTAssertNil(w.pairing); XCTAssertNil(w.error)
    }
}

/// Holds the actual production completion immediately before publication. Deliberately
/// ignores cancellation so obsolete successes and failures must pass the real guards.
@MainActor private final class CompletionGate {
    private var waiting: [String: CheckedContinuation<Void, Error>] = [:]
    private(set) var entered: Set<String> = []
    let points: Set<String>
    init(_ points: String...) { self.points = Set(points) }
    func pause(_ point: String) async throws {
        guard points.contains(point) else { return }
        entered.insert(point)
        try await withCheckedThrowingContinuation { waiting[point] = $0 }
    }
    func wait(_ point: String) async throws {
        for _ in 0..<500 {
            if entered.contains(point) { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Production completion did not reach \(point)")
        throw CocoaError(.coderInvalidValue)
    }
    func release(_ point: String, fail: Bool = false) {
        let continuation = waiting.removeValue(forKey: point)
        if fail { continuation?.resume(throwing: CocoaError(.fileReadUnknown)) }
        else { continuation?.resume() }
    }
    func releaseAll() { for key in Array(waiting.keys) { release(key) } }
}

@MainActor final class WorkspaceCompletionTests: XCTestCase {
    nonisolated(unsafe) private var root: URL!
    private final class Uncertain: @unchecked Sendable {
        func check(_ point: RecoveryFaultPoint) throws {
            if point == .afterClearRemoval { throw RecoveryError.injected(point) }
        }
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-Completions-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 96, height: 64)).image { c in
            UIColor.systemTeal.setFill(); c.fill(CGRect(x: 0, y: 0, width: 96, height: 64))
        }
        try XCTUnwrap(image.pngData()).write(to: root.appendingPathComponent("original.png"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func workspace(uncertain: Bool = false) async -> Workspace {
        let fault = Uncertain()
        let injection: (@Sendable (RecoveryFaultPoint) throws -> Void)?
        if uncertain { injection = { @Sendable point in try fault.check(point) } } else { injection = nil }
        let w = Workspace(qaDirectory: root.appendingPathComponent(UUID().uuidString), fault: injection)
        await w.startup(); await w.preparePhoto(root.appendingPathComponent("original.png"))
        w.tap(CGPoint(x: 0.2, y: 0.3), hit: nil); await w.flush()
        return w
    }
    private func clear(_ w: Workspace, thenOpen: Bool = false) async throws {
        w.requestClear(); let target = try XCTUnwrap(w.clearTarget)
        await w.confirmClear(target)
        if thenOpen {
            await w.preparePhoto(root.appendingPathComponent("original.png"))
            w.tap(CGPoint(x: 0.7, y: 0.8), hit: nil); await w.flush()
        }
    }
    private func unchanged(_ w: Workspace, _ snapshot: RecoverySnapshot?, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(w.snapshot, snapshot, file: file, line: line)
        XCTAssertNil(w.error, file: file, line: line); XCTAssertNil(w.pending, file: file, line: line)
        XCTAssertNil(w.pairing, file: file, line: line); XCTAssertFalse(w.showPairing, file: file, line: line)
        XCTAssertFalse(w.showReplacement, file: file, line: line); XCTAssertFalse(w.busy, file: file, line: line)
    }
    func testHeldPhotoFilesJSONAndDetailCompletionsCannotPublishAfterClear() async throws {
        // 6 actual completion paths × success/error × durable empty/retained uncertain/new workspace.
        for point in ["photoTransferCompletion", "filesPickerCompletion", "jsonPickerCompletion", "photoPrepareCompletion", "jsonDecodeCompletion", "detailCompletion"] {
            for boundary in 0..<3 { for failure in [false, true] {
                let w = await workspace(uncertain: boundary == 1), gate = CompletionGate(point)
                defer { gate.releaseAll() }
                let json = root.appendingPathComponent("\(UUID()).json")
                try XCTUnwrap(w.document).encoded().write(to: json)
                let request = try XCTUnwrap(w.newRequest())
                w.qaSuspend = { try await gate.pause($0) }
                let task: Task<Void, Never>
                switch point {
                case "photoTransferCompletion":
                    task = Task { await w.receivePhotoTransfer(request, isCurrent: { true }) { try PickedPhoto.importFile(self.root.appendingPathComponent("original.png")) } }
                case "filesPickerCompletion", "jsonPickerCompletion":
                    let isJSON = point == "jsonPickerCompletion"
                    if isJSON { w.jsonRequest = request } else { w.filesRequest = request }
                    task = Task { await w.receiveFileResult(.success([isJSON ? json : self.root.appendingPathComponent("original.png")]), request: request, json: isJSON) }
                case "photoPrepareCompletion":
                    task = Task { await w.preparePhoto(self.root.appendingPathComponent("original.png")) }
                case "jsonDecodeCompletion": task = Task { await w.prepareJSON(json) }
                default:
                    let old = try XCTUnwrap(w.candidate)
                    let tiny = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }.cgImage)
                    w.candidate = ImageCandidate(sourceURL: old.sourceURL, identity: old.identity, preview: tiny)
                    w.requestDetail(); task = try XCTUnwrap(w.qaDetailTask)
                }
                try await gate.wait(point)
                w.qaSuspend = nil // New work is not held by the obsolete completion's gate.
                try await clear(w, thenOpen: boundary == 2)
                XCTAssertEqual(w.clearFailed, boundary == 1)
                let current = w.snapshot, candidate = w.candidate
                let message = w.recoveryMessage
                gate.release(point, fail: failure); await task.value
                unchanged(w, current); XCTAssertEqual(w.recoveryMessage, message)
                XCTAssertEqual(w.candidate?.sourceURL, candidate?.sourceURL)
                XCTAssertEqual(w.candidate?.preview.width, candidate?.preview.width)
            } }
        }
    }
    func testHeldStartupCannotInstallOrEndNewerOpeningAfterClear() async throws {
        for boundary in 0..<3 { for failure in [false, true] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            let seed = Workspace(qaDirectory: directory)
            await seed.startup(); await seed.preparePhoto(root.appendingPathComponent("original.png")); await seed.flush()
            let fault = Uncertain()
            let w = Workspace(qaDirectory: directory, fault: { @Sendable point in if boundary == 1 { try fault.check(point) } })
            let gate = CompletionGate("startupCompletion", "jsonDecodeCompletion")
            defer { gate.releaseAll() }
            w.qaSuspend = { try await gate.pause($0) }
            let startup = Task { await w.startup() }; try await gate.wait("startupCompletion")
            await w.preparePhoto(root.appendingPathComponent("original.png"))
            try await clear(w, thenOpen: boundary == 2)
            let current = w.snapshot
            if boundary != 2 {
                gate.release("startupCompletion", fail: failure); await startup.value
                unchanged(w, current); XCTAssertEqual(w.clearFailed, boundary == 1)
                continue
            }
            let json = root.appendingPathComponent("\(UUID()).json"); try XCTUnwrap(w.document).encoded().write(to: json)
            let opening = Task { await w.prepareJSON(json) }; try await gate.wait("jsonDecodeCompletion")
            gate.release("startupCompletion", fail: failure); await startup.value
            XCTAssertTrue(w.busy, "Obsolete startup finalizer cannot end newer opening")
            XCTAssertEqual(w.snapshot, current); XCTAssertNil(w.error); XCTAssertNil(w.pairing)
            w.cancelOpening(); gate.release("jsonDecodeCompletion"); await opening.value
            unchanged(w, current)
        } }
    }
    func testHeldSaveAndFinalizerDrainBeforeClearAndCannotRetireNextJob() async throws {
        for uncertain in [false, true] { for failure in [false, true] {
        let w = await workspace(uncertain: uncertain), gate = CompletionGate("saveCompletion", "saveFinalizer")
        defer { gate.releaseAll() }
        w.qaSuspend = { try await gate.pause($0) }
        w.tap(CGPoint(x: 0.6, y: 0.6), hit: nil)
        try await gate.wait("saveCompletion"); let oldJob = try XCTUnwrap(w.qaSaveJob)
        w.requestClear(); let target = try XCTUnwrap(w.clearTarget)
        let clearing = Task { await w.confirmClear(target) }
        for _ in 0..<100 where !w.clearing { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(w.clearing); XCTAssertNil(w.qaSaveJob)
        gate.release("saveCompletion", fail: failure); try await gate.wait("saveFinalizer")
        XCTAssertTrue(w.clearing); XCTAssertFalse(w.canOpen)
        w.qaSuspend = nil; gate.release("saveFinalizer"); await clearing.value
        XCTAssertEqual(w.candidate == nil, !uncertain); XCTAssertEqual(w.clearFailed, uncertain); XCTAssertNil(w.error)
        if !uncertain { await w.preparePhoto(root.appendingPathComponent("original.png")) }
        let next = CompletionGate("saveCompletion"); defer { next.releaseAll() }
        w.qaSuspend = { try await next.pause($0) }; w.tap(CGPoint(x: 0.8, y: 0.8), hit: nil)
        try await next.wait("saveCompletion"); let newJob = try XCTUnwrap(w.qaSaveJob)
        XCTAssertNotEqual(newJob, oldJob); XCTAssertEqual(w.qaSaveJob, newJob)
        w.qaSuspend = nil; next.release("saveCompletion"); await w.flush(); XCTAssertNil(w.qaSaveJob)
        } }
    }
    func testHeldExportCopyPreservesReaderAndSuppressesOldStatusAndBaseline() async throws {
        for boundary in 0..<3 { for failure in [false, true] {
            let w = await workspace(uncertain: boundary == 1), gate = CompletionGate("exportCopy", "exportCompletion")
            defer { gate.releaseAll() }
            let document = try XCTUnwrap(w.document), snapshot = try XCTUnwrap(w.snapshot)
            let source = try XCTUnwrap(w.candidate).sourceURL, bytes = try Data(contentsOf: source)
            let state = ExportSaveState(), destination = root.appendingPathComponent("\(UUID()).png")
            let request = ExportSaveState.Request(source: source, filename: destination.lastPathComponent, kind: "Original Photo")
            w.qaSuspend = { try await gate.pause($0) }
            let copying = Task { await state.save(.init(request: request, url: destination, scopedFolder: nil), workspace: w, document: document, workspaceID: snapshot.workspaceID, sourceToken: snapshot.sourceToken) }
            try await gate.wait("exportCopy"); w.qaSuspend = nil
            try await clear(w, thenOpen: boundary == 2)
            let current = w.snapshot
            XCTAssertEqual(try Data(contentsOf: source), bytes, "In-flight copy retains old source through clear")
            // Retain the completion seam for this already-running copy only.
            w.qaSuspend = { try await gate.pause($0) }; gate.release("exportCopy")
            try await gate.wait("exportCompletion")
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            if boundary != 1 { XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)) }
            gate.release("exportCompletion", fail: failure); await copying.value; w.qaSuspend = nil
            unchanged(w, current); XCTAssertFalse(state.closed); XCTAssertFalse(state.saving)
            XCTAssertTrue(state.status.isEmpty); XCTAssertNil(state.error); XCTAssertNil(state.retry)
            XCTAssertEqual(try Data(contentsOf: destination), bytes)
            // JSON uses the same completion guard and is the only baseline-mutating output.
            let json = root.appendingPathComponent("\(UUID()).json"); try document.encoded().write(to: json)
            let live = await workspace(uncertain: boundary == 1), jsonGate = CompletionGate("exportCompletion")
            defer { jsonGate.releaseAll() }
            let liveDoc = try XCTUnwrap(live.document), liveID = try XCTUnwrap(live.snapshot?.workspaceID)
            let jsonState = ExportSaveState(), jsonOutput = root.appendingPathComponent("\(UUID()).json")
            live.qaSuspend = { try await jsonGate.pause($0) }
            let jsonCopy = Task { await jsonState.save(.init(request: .init(source: json, filename: jsonOutput.lastPathComponent, kind: "JSON"), url: jsonOutput, scopedFolder: nil), workspace: live, document: liveDoc, workspaceID: liveID) }
            try await jsonGate.wait("exportCompletion"); live.qaSuspend = nil
            try await clear(live, thenOpen: boundary == 2); let after = live.snapshot
            jsonGate.release("exportCompletion", fail: failure); await jsonCopy.value
            unchanged(live, after); XCTAssertTrue(jsonState.status.isEmpty); XCTAssertNil(jsonState.error); XCTAssertNil(jsonState.retry)
            XCTAssertEqual(try Data(contentsOf: jsonOutput), try Data(contentsOf: json))
        } }
    }
    func testSyntheticDetectorProgressResultDeadlineAndFinalizerDrainAcrossClear() async throws {
        let suggestion = BirdSuggestion(id: "synthetic", x: 0.3, y: 0.4, width: 0.1, height: 0.1, score: 0.9)
        for boundary in 0..<3 { for failure in [false, true] {
            let w = await workspace(uncertain: boundary == 1)
            let gate = CompletionGate("birdProgress", "result", "deadline", "birdFinalizer")
            defer { gate.releaseAll() }
            w.qaSuspend = { try await gate.pause($0) }
            w.qaBirdDeadlineWait = { try? await gate.pause("deadline") }
            w.qaBirdScan = { _, progress in
                await progress(1, 2); try await gate.pause("result"); return [suggestion]
            }
            w.startBirdDetection(); let task = try XCTUnwrap(w.birdTask)
            try await gate.wait("birdProgress"); try await gate.wait("deadline")
            let oldSource = try XCTUnwrap(w.candidate).sourceURL
            w.qaSuspend = nil; try await clear(w, thenOpen: boundary == 2)
            let current = w.snapshot, message = w.birdMessage
            XCTAssertEqual(w.birdActivity, .idle); XCTAssertTrue(w.birdOwner)
            gate.release("birdProgress"); try await gate.wait("result")
            XCTAssertEqual(w.birdActivity, .idle, "Obsolete production progress is ignored")
            gate.release("deadline"); try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(w.birdActivity, .idle); XCTAssertEqual(w.birdMessage, message)
            w.qaSuspend = { try await gate.pause($0) }
            gate.release("result", fail: failure); try await gate.wait("birdFinalizer")
            XCTAssertTrue(w.birdOwner); XCTAssertFalse(w.canDetectBirds)
            if boundary != 1 { XCTAssertFalse(FileManager.default.fileExists(atPath: oldSource.path)) }
            gate.release("birdFinalizer"); await task.value; w.qaSuspend = nil
            unchanged(w, current); XCTAssertNil(w.birdReview); XCTAssertNil(w.birdMeasurement)
            XCTAssertEqual(w.birdActivity, .idle); XCTAssertEqual(w.birdMessage, message); XCTAssertFalse(w.birdOwner)
            if boundary == 2 { XCTAssertTrue(w.canDetectBirds, "New scan admission resumes after the old owner drains") }
        } }
    }


}
