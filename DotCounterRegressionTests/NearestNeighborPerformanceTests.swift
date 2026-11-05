import XCTest
import SwiftUI
import UIKit
import DotCounterCore
@testable import DotCounter

/// Native Debug evidence; handler entry through actual canvas drawing and a
/// subsequent display opportunity. This does not measure physical scanout.
@MainActor final class NearestNeighborPerformanceTests: XCTestCase {
    @MainActor private final class FrameProbe: NSObject {
        var callback: (() -> Void)?
        @objc func frame(_ link: CADisplayLink) { callback?() }
    }
    private func canvas(in view: UIView) -> TouchCanvas? {
        if let canvas = view as? TouchCanvas { return canvas }
        return view.subviews.compactMap { canvas(in: $0) }.first
    }
    private func visible(_ view: TouchCanvas, action: () -> Void, matches: @escaping () -> Bool = { true }) async -> (Double, Double) {
        let start = CACurrentMediaTime(), probe = FrameProbe()
        var drawn = false, drawDuration = 0.0
        let link = CADisplayLink(target: probe, selector: #selector(FrameProbe.frame(_:)))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            probe.callback = { if drawn { probe.callback = nil; link.invalidate(); continuation.resume() } }
            view.engine.qaDidDraw = { duration in
                if matches() { drawn = true; drawDuration = max(drawDuration, duration) }
            }
            link.add(to: .main, forMode: .common)
            action()
            view.setNeedsDisplay()
        }
        view.engine.qaDidDraw = nil
        return ((CACurrentMediaTime() - start) * 1000, drawDuration * 1000)
    }
    /// Independent QA counterexample probe. Records production native drawing,
    /// without treating an offscreen raster or warm Fit result as zoom latency.
    func testQADenseColdAndZoomVisibleResponseEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearestIndependentQA-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.png")
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 1300, height: 813)).image { context in
            UIColor(white: 0.8, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1300, height: 813))
        }
        try XCTUnwrap(photo.pngData()).write(to: source)
        let w = Workspace(qaDirectory: root.appendingPathComponent("recovery"))
        await w.startup(); await w.preparePhoto(source)
        let controller = UIHostingController(rootView: WorkspaceView(workspace: w))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        defer { window.isHidden = true }
        for _ in 0..<100 where canvas(in: controller.view) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let view = try XCTUnwrap(canvas(in: controller.view))
        let markers = (0..<100_000).map { index in
            Marker(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                   x: (Double(index % 400) + 0.5) / 400,
                   y: (Double(index / 400) + 0.5) / 250)
        }
        var rows: [[String: Any]] = []
        func record(_ name: String, action: () -> Void, matches: @escaping () -> Bool = { true }) async {
            let result = await visible(view, action: action, matches: matches)
            let row: [String: Any] = ["action": name, "visibleResponseMS": result.0, "mainActorDrawMS": result.1]
            rows.append(row); print("NEAREST_INDEPENDENT_QA \(row)")
        }
        await record("cold-100k-grid-Fit") {
            w.history = MarkerHistory(markers: markers)
            let old = w.snapshot!
            w.snapshot = RecoverySnapshot(workspaceID: old.workspaceID, revision: old.revision + 1,
                sourceToken: old.sourceToken, image: old.image, markers: markers, baselineDigest: old.baselineDigest)
            w.setConnectionsVisible(true)
        } matches: { view.engine.connections.isVisible && w.total == 100_000 }
        await record("warm-Fit-hide", action: { w.setConnectionsVisible(false) }, matches: { !view.engine.connections.isVisible })
        await record("warm-Fit-show", action: { w.setConnectionsVisible(true) }, matches: { view.engine.connections.isVisible })
        await record("zoom-2x", action: { view.engine.zoom(2, at: CGPoint(x: view.bounds.midX, y: view.bounds.midY)) })
        await record("zoomed-hide", action: { w.setConnectionsVisible(false) }, matches: { !view.engine.connections.isVisible })
        await record("zoomed-show", action: { w.setConnectionsVisible(true) }, matches: { view.engine.connections.isVisible })
        await record("zoomed-pan", action: { view.engine.pan(CGSize(width: 2, height: 1)) })
        XCTAssertEqual(w.markers, markers, "Rendering operations preserve the complete count")
        let data = try JSONSerialization.data(withJSONObject: ["count": 100_000, "layout": "grid400", "rows": rows,
            "method": "production handler entry to matching actual native canvas draw and next CADisplayLink; draw runs on MainActor; no scanout claim"], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "nearest-independent-cold-zoom.json"; attachment.lifetime = .keepAlways; add(attachment)
        await w.flush()
    }
    func testBoundedParallelSurfacePreparationAtNormalCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearestBounded-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.png")
        let photo = UIGraphicsImageRenderer(size: CGSize(width: 1300, height: 813)).image { context in
            UIColor(white: 0.8, alpha: 1).setFill(); context.fill(CGRect(x: 0, y: 0, width: 1300, height: 813))
        }
        try XCTUnwrap(photo.pngData()).write(to: source)
        let w = Workspace(qaDirectory: root.appendingPathComponent("recovery"))
        await w.startup(); await w.preparePhoto(source)
        let controller = UIHostingController(rootView: WorkspaceView(workspace: w))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        defer { window.isHidden = true }
        for _ in 0..<100 where canvas(in: controller.view) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let view = try XCTUnwrap(canvas(in: controller.view))
        for count in [1_000, 10_000] {
            let columns = 100
            let markers = (0..<count).map { index in Marker(x: (Double(index % columns)+0.5)/Double(columns),
                y: (Double(index / columns)+0.5)/Double(count / columns)) }
            for serial in [true, false] {
                view.engine.qaSerialSurfacePreparation = serial
                let cold = await visible(view, action: {
                    w.history = MarkerHistory(markers: markers)
                    let old = w.snapshot!
                    w.snapshot = RecoverySnapshot(workspaceID: old.workspaceID, revision: old.revision+1,
                        sourceToken: old.sourceToken, image: old.image, markers: markers, baselineDigest: old.baselineDigest)
                    w.setConnectionsVisible(true)
                }, matches: { view.engine.connections.isVisible && w.total == count })
                let hide = await visible(view, action: { w.setConnectionsVisible(false) }, matches: { !view.engine.connections.isVisible })
                let show = await visible(view, action: { w.setConnectionsVisible(true) }, matches: { view.engine.connections.isVisible })
                print("NEAREST_BOUNDED count=\(count) preparation=\(serial ? "serial" : "parallel") coldVisibleMS=\(cold.0) mainDrawMS=\(cold.1) hideVisibleMS=\(hide.0) showVisibleMS=\(show.0)")
                XCTAssertEqual(w.markers, markers)
            }
        }
        await w.flush()
    }

    func testParallelPreparationCancellationDrainsAndReleasesAdmission() async throws {
        let photo = try XCTUnwrap(UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }.cgImage)
        let markers = (0..<10_000).map { Marker(x: Double($0 % 100)/100, y: Double($0 / 100)/100) }
        let control = NearestNeighborCancellation()
        let running = Task.detached {
            try CanvasEngine.qaPrepareSurfaces(markers: markers, photo: photo, size: CGSize(width: 640, height: 400), control: control)
        }
        try await Task.sleep(for: .milliseconds(20))
        let started = CACurrentMediaTime(); control.cancel()
        do { try await running.value; XCTFail("Cancelled pair must not publish") } catch is CancellationError {} catch { XCTFail("Unexpected error \(error)") }
        let drainedMS = (CACurrentMediaTime()-started)*1000
        print("NEAREST_BOUNDED cancelToBothJobsDrainedMS=\(drainedMS)")
        XCTAssertLessThan(drainedMS, 500, "Both jobs should observe cancellation within one short marker batch")
        // A fresh request must acquire the same global admission after failure.
        try await Task.detached {
            try CanvasEngine.qaPrepareSurfaces(markers: Array(markers.prefix(10)), photo: photo,
                size: CGSize(width: 640, height: 400), control: .init())
        }.value
    }
    func testCachedMarkerSurfaceMatchesDirectDrawingAndInvalidatesForLiveGeometry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearestCache-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 400)).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 400))
        }
        try XCTUnwrap(image.pngData()).write(to: source)
        let w = Workspace(qaDirectory: root.appendingPathComponent("recovery"))
        await w.startup(); await w.preparePhoto(source)
        var markers = (0..<2_000).map { index in Marker(x: Double(index % 100) / 99, y: Double(index / 100) / 19) }
        markers[0] = Marker(x: 0.5, y: 0.5)
        w.history = MarkerHistory(markers: markers)
        let old = try XCTUnwrap(w.snapshot)
        w.snapshot = RecoverySnapshot(workspaceID: old.workspaceID, revision: old.revision + 1, sourceToken: old.sourceToken,
            image: old.image, markers: markers, baselineDigest: old.baselineDigest)
        w.setConnectionsVisible(true)
        let engine = CanvasEngine(w); engine.update(size: CGSize(width: 640, height: 400))
        func raster(direct: Bool) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 800, bitsPerComponent: 8, bytesPerRow: 1280 * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: 800); context.scaleBy(x: 2, y: -2)
            engine.qaDisableMarkerCache = direct; engine.draw(context, size: CGSize(width: 640, height: 400))
            return Data(bytes: try XCTUnwrap(context.data), count: 1280 * 800 * 4)
        }
        func verify(_ name: String, edgeRounding: Int = 0) throws {
            let cached = try raster(direct: false), direct = try raster(direct: true)
            var maximum = 0, differences = 0
            for index in cached.indices {
                let difference = abs(Int(cached[index]) - Int(direct[index]))
                maximum = max(maximum, difference); if difference > 0 { differences += 1 }
            }
            print("NEAREST_CACHE_PARITY \(name) maxChannelDelta=\(maximum) differingChannels=\(differences)")
            XCTAssertLessThanOrEqual(maximum, edgeRounding, name)
        }
        for style in MarkerAppearance.Style.allCases { for color in MarkerAppearance.Color.allCases {
            w.setMarkerStyle(style); w.setMarkerColor(color); engine.appearance = w.appearance; engine.connections = w.connections
            try verify("\(style) \(color)")
        } }
        engine.pan(CGSize(width: 4, height: 2))
        try verify("Panning repositions the complete cached surface", edgeRounding: 1)
        engine.zoom(2, at: CGPoint(x: 320, y: 200))
        try verify("Zoom changes the cache key and keeps screen-point sizes")
        engine.movingID = markers[0].id; engine.preview = CGPoint(x: 0.3, y: 0.3)
        try verify("Live movement uses shared center resolution")
        await w.flush()
    }

    func testNativePhotoStyleAndProgressCaptures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearestCapture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let w = Workspace(qaDirectory: root)
        await w.startup()
        let photo = try XCTUnwrap(Bundle.main.url(forResource: "QA-flock", withExtension: "jpg"))
        await w.preparePhoto(photo)
        for point in [CGPoint(x: 0.15, y: 0.28), CGPoint(x: 0.22, y: 0.4), CGPoint(x: 0.31, y: 0.32),
                      CGPoint(x: 0.44, y: 0.47), CGPoint(x: 0.5, y: 0.28), CGPoint(x: 0.61, y: 0.37),
                      CGPoint(x: 0.67, y: 0.5), CGPoint(x: 0.76, y: 0.32), CGPoint(x: 0.85, y: 0.5)] { w.tap(point, hit: nil) }
        w.renumber(.nearestNeighbor); await w.qaRenumberTask?.value
        let controller = UIHostingController(rootView: WorkspaceView(workspace: w))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        defer { window.isHidden = true }
        func capture(_ name: String) {
            let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        }
        for style in MarkerAppearance.Style.allCases {
            w.setMarkerStyle(style); w.setMarkerColor(style == .plainDots ? .coral : .legacy)
            try await Task.sleep(for: .milliseconds(180)); capture("Native photo connections \(style.name)")
        }
        w.setConnectionsVisible(false); try await Task.sleep(for: .milliseconds(120)); capture("Native photo connections hidden")
        var resume: CheckedContinuation<Void, Never>?
        w.qaSuspend = { point in if point == "renumberCompletion" { await withCheckedContinuation { resume = $0 } } }
        w.renumber(.nearestNeighbor)
        try await Task.sleep(for: .milliseconds(400)); XCTAssertTrue(w.renumberProgress)
        capture("Native pending Renumber with reachable Cancel")
        w.cancelRenumber(); resume?.resume(); await w.qaRenumberTask?.value; w.qaSuspend = nil
        await w.flush()
    }

    func testNativeCapacityCompletionAndVisibilityEvidence() async throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NearestPerformance-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("synthetic.png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1300, height: 813)).image { ctx in
            UIColor(white: 0.8, alpha: 1).setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 1300, height: 813))
        }
        try XCTUnwrap(image.pngData()).write(to: url)
        let w = Workspace(qaDirectory: root.appendingPathComponent("recovery"))
        await w.startup(); await w.preparePhoto(url)
        let controller = UIHostingController(rootView: WorkspaceView(workspace: w))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = controller; window.makeKeyAndVisible()
        controller.view.frame = window.bounds; controller.view.layoutIfNeeded()
        defer { window.isHidden = true }
        for _ in 0..<100 where canvas(in: controller.view) == nil { try await Task.sleep(for: .milliseconds(20)) }
        let view = try XCTUnwrap(canvas(in: controller.view))
        var results: [[String: Any]] = []
        for count in [1_000, 10_000, 100_000] {
            for coincident in [false, true] {
                var markers: [Marker] = []
                let columns = 400
                for index in 0..<count {
                    markers.append(Marker(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012x", index + 1))!,
                        x: coincident ? 0.5 : (Double(index % columns) + 0.5) / Double(columns),
                        y: coincident ? 0.5 : (Double(index / columns) + 0.5) / Double((count + columns - 1) / columns)))
                }
                markers.reverse()
                w.invalidateRenumber(); w.history = MarkerHistory(markers: markers)
                let old = try XCTUnwrap(w.snapshot)
                w.snapshot = RecoverySnapshot(workspaceID: old.workspaceID, revision: old.revision + 1, sourceToken: old.sourceToken,
                    image: old.image, markers: markers, baselineDigest: old.baselineDigest)
                w.setConnectionsVisible(false)
                let completion = await visible(view, action: { w.renumber(.nearestNeighbor) }, matches: { !w.renumberPending })
                XCTAssertFalse(w.renumberFailure); XCTAssertEqual(w.total, count)
                XCTAssertEqual(w.markers.first?.id, UUID(uuidString: "00000000-0000-0000-0000-000000000001"), "A complete route, not cancellation, must reach the display")
                let hide = await visible(view, action: { w.setConnectionsVisible(false) }, matches: { !view.engine.connections.isVisible })
                let show = await visible(view, action: { w.setConnectionsVisible(true) }, matches: { view.engine.connections.isVisible })
                let navigation = await visible(view, action: { view.engine.pan(CGSize(width: 2, height: 1)) })
                let row: [String: Any] = ["count": count, "layout": coincident ? "coincident" : "grid", "completionMS": completion.0,
                    "completionDrawMS": completion.1, "hideMS": hide.0, "showMS": show.0, "navigationMS": navigation.0,
                    "maxDrawMS": max(completion.1, hide.1, show.1, navigation.1)]
                results.append(row)
                print("NEAREST_NATIVE_METRIC \(row)")
                if count == 1_000 && !coincident {
                    let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                        window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                    }); attachment.name = "Nearest Neighbor native 1000 grid connections"; attachment.lifetime = .keepAlways; add(attachment)
                }
                await w.flush()
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["method": "native handler entry to matching canvas draw + next CADisplayLink opportunity; no physical scanout", "rows": results], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json"); attachment.name = "nearest-native-capacity.json"; attachment.lifetime = .keepAlways; add(attachment)
        // Timings are evidence, not assertions that disguise missed budgets.
    }
}
