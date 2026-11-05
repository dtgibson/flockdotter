import XCTest
import CoreGraphics
@testable import DotCounterCore

final class CoreTests: XCTestCase {
    let image = ImageIdentity(sha256: String(repeating: "a", count: 64), pixelWidth: 6000, pixelHeight: 4000, originalFilename: "flock.heic")

    func testStrictSpatialSortAndReversibleCommands() throws {
        let a = Marker(x: 0.7, y: 0.2), b = Marker(x: 0.2, y: 0.8)
        let c = Marker(x: 0.2, y: 0.3), d = Marker(x: 0.2, y: 0.3)
        let initial = [a, b, c, d]
        var history = MarkerHistory(markers: initial)
        XCTAssertTrue(history.renumber(.leftToRight))
        XCTAssertEqual(history.markers.map(\.id), [c.id, d.id, b.id, a.id])
        XCTAssertFalse(history.renumber(.leftToRight))
        XCTAssertEqual(history.undoCount, 1)
        XCTAssertTrue(history.undo())
        XCTAssertEqual(history.markers, initial)
        XCTAssertTrue(history.renumber(.topToBottom))
        XCTAssertEqual(history.markers.map(\.id), [a.id, c.id, d.id, b.id])
        XCTAssertFalse(history.canRedo)
        let ordered = history.markers
        XCTAssertTrue(history.move(id: c.id, x: 0.91, y: 0.1))
        XCTAssertEqual(history.markers.map(\.id), ordered.map(\.id))
        XCTAssertTrue(history.delete(id: d.id))
        XCTAssertEqual(history.markers.map(\.id), [a.id, c.id, b.id])
        XCTAssertTrue(history.add(x: 0, y: 1))
        let added = history.markers.last!
        for _ in 0..<3 { XCTAssertTrue(history.undo()) }
        XCTAssertEqual(history.markers, ordered)
        for _ in 0..<3 { XCTAssertTrue(history.redo()) }
        XCTAssertEqual(history.markers.map(\.id), [a.id, c.id, b.id, added.id])
        XCTAssertEqual(history.markers[1].x, 0.91)
        XCTAssertFalse(history.move(id: c.id, x: 0.91, y: 0.1))
        XCTAssertFalse(history.move(id: c.id, x: 1.01, y: 0.1))
    }

    func testHistoryRetainsExactlyLatestThousandCommands() {
        var history = MarkerHistory()
        for index in 0..<1001 { XCTAssertTrue(history.add(x: Double(index) / 1001, y: 0.5)) }
        XCTAssertEqual(history.undoCount, 1000)
        for _ in 0..<1000 { XCTAssertTrue(history.undo()) }
        XCTAssertEqual(history.markers.count, 1)
        XCTAssertFalse(history.undo())
        for _ in 0..<1000 { XCTAssertTrue(history.redo()) }
        XCTAssertEqual(history.markers.count, 1001)
        XCTAssertFalse(history.redo())

        // Core-command timings isolate model work; they do not measure SwiftUI,
        // frame presentation, autosave or physical-device latency.
        var samples: [Double] = []
        for index in 0..<100 {
            let started = DispatchTime.now().uptimeNanoseconds
            switch index % 3 {
            case 0: _ = history.add(x: Double(index) / 100, y: 0.4)
            case 1: _ = history.delete(id: history.markers.last!.id)
            default: _ = history.undo()
            }
            _ = history.markers.count
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
        }
        samples.sort()
        let passing = samples.filter { $0 <= 100 }.count
        print("CORE_COMMAND_BENCHMARK samples=100 initialMarkers=1001 mainThread=\(Thread.isMainThread) configuration=Debug p50ms=\(samples[49]) p95ms=\(samples[94]) maxms=\(samples[99]) within100ms=\(passing)")
        XCTAssertGreaterThanOrEqual(passing, 95)
    }

    func testSortUsesUnroundedDoublesAndStableExactTies() {
        let near = Marker(x: 0.20000000000000004, y: 0.1)
        let exact = Marker(x: 0.2, y: 0.9)
        var history = MarkerHistory(markers: [near, exact])
        XCTAssertTrue(history.renumber(.leftToRight))
        XCTAssertEqual(history.markers.map(\.id), [exact.id, near.id])
    }

    func testJSONRoundTripOrderEdgesAndExactDigest() throws {
        let markers = [Marker(x: 1, y: 0), Marker(x: 0.12345678901234567, y: 0.9999999999999999), Marker(x: -0.0, y: 1)]
        let document = CountDocument(image: image, markers: markers)
        let encoded = try document.encoded()
        let reopened = try CountDocument.decode(encoded)
        XCTAssertEqual(reopened, document)
        XCTAssertEqual(reopened.contentDigest, document.contentDigest)
        for (a, b) in zip(markers, reopened.markers) {
            XCTAssertLessThanOrEqual(abs(a.x - b.x) * 6000, 0.1)
            XCTAssertLessThanOrEqual(abs(a.y - b.y) * 4000, 0.1)
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["format", "version", "image", "markers"]))
        let empty = CountDocument(image: image)
        XCTAssertEqual(try CountDocument.decode(empty.encoded()).markers, [])
        var history = MarkerHistory(markers: markers)
        let baseline = document.contentDigest
        history.add(x: 0.8, y: 0.8)
        XCTAssertNotEqual(CountDocument(image: image, markers: history.markers).contentDigest, baseline)
        history.undo()
        XCTAssertEqual(CountDocument(image: image, markers: history.markers).contentDigest, baseline)
    }

    func testJSONStrictTypesDuplicatesRangesAndUnsupportedVersion() throws {
        let good = String(decoding: try CountDocument(image: image, markers: [Marker(x: 0.2, y: 0.4)]).encoded(), as: UTF8.self)
        let malformed: [String] = [
            good.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : true"),
            good.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : \"1\""),
            good.replacingOccurrences(of: "\"pixelWidth\" : 6000", with: "\"pixelWidth\" : 1.5"),
            good.replacingOccurrences(of: "\"pixelWidth\" : 6000", with: "\"pixelWidth\" : 5999.9999999999999999999"),
            good.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 1.0000000000000000001"),
            good.replacingOccurrences(of: "\"pixelWidth\" : 6000", with: "\"pixelWidth\" : false"),
            good.replacingOccurrences(of: "\"pixelWidth\" : 6000", with: "\"pixelWidth\" : 1e100"),
            good.replacingOccurrences(of: "\"pixelWidth\" : 6000", with: "\"pixelWidth\" : 0"),
            good.replacingOccurrences(of: "\"x\" : 0.2", with: "\"x\" : true"),
            good.replacingOccurrences(of: "\"x\" : 0.2", with: "\"x\" : -0.0001"),
            good.replacingOccurrences(of: "\"x\" : 0.2", with: "\"x\" : 1.0001"),
            good.replacingOccurrences(of: "\"x\" : 0.2", with: "\"x\" : 1e999"),
            good.replacingOccurrences(of: "\"x\" : 0.2", with: "\"x\" : NaN"),
            good.replacingOccurrences(of: "\"x\" : 0.2", with: "\"x\" : 0.2, \"x\" : 0.3"),
            good.replacingOccurrences(of: "\"image\" : {", with: "\"version\": 1, \"image\" : {"),
            good.replacingOccurrences(of: "flock.heic", with: "../flock.heic"),
            good.replacingOccurrences(of: "flock.heic", with: "folder\\\\flock.heic"),
            good.replacingOccurrences(of: "flock.heic", with: "flock\\u0000.heic"),
            good.replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "A", count: 64)),
            String(good.dropLast()), "[]", "null", "{\"format\":\"dotcounter\",\"version\":1}"
        ]
        for (index, json) in malformed.enumerated() {
            XCTAssertNotEqual(json, good, "Malformed fixture \(index) did not change input")
            XCTAssertThrowsError(try CountDocument.decode(Data(json.utf8)), "Fixture \(index) was accepted")
        }
        let unsupported = good.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        XCTAssertThrowsError(try CountDocument.decode(Data(unsupported.utf8))) { XCTAssertEqual($0 as? CountError, .unsupportedVersion) }
        XCTAssertThrowsError(try CountDocument.decode(Data([0xff, 0xfe, 0x00])))
    }

    func testDuplicateIDsCaseInsensitiveUnknownFieldsIgnoredAndCoordinatesMayCoincide() throws {
        let id = UUID()
        let document = CountDocument(image: image, markers: [Marker(id: id, x: 0.2, y: 0.2), Marker(x: 0.2, y: 0.2)])
        var text = String(decoding: try document.encoded(), as: UTF8.self)
        text = text.replacingOccurrences(of: "\"format\"", with: "\"unknown\": {\"url\": \"file:///not-used\"}, \"format\"")
        XCTAssertEqual(try CountDocument.decode(Data(text.utf8)), document)
        text = text.replacingOccurrences(of: document.markers[1].id.uuidString, with: id.uuidString.lowercased())
        XCTAssertThrowsError(try CountDocument.decode(Data(text.utf8)))
        XCTAssertThrowsError(try CountDocument.decode(Data(repeating: 32, count: ResourceLimits.maxJSONBytes + 1)))
    }

    func testFilenameIsHintAndNegativeZeroNormalizes() throws {
        var renamed = image
        renamed.originalFilename = "renamed.png"
        XCTAssertTrue(image.matches(renamed))
        renamed.sha256 = String(repeating: "b", count: 64)
        XCTAssertFalse(image.matches(renamed))
        let id = UUID()
        let negative = CountDocument(image: image, markers: [Marker(id: id, x: -0.0, y: -0.0)])
        let positive = CountDocument(image: image, markers: [Marker(id: id, x: 0, y: 0)])
        XCTAssertEqual(negative.contentDigest, positive.contentDigest)
    }

    func testViewportEdgesFocalZoomResizeAndDeterministicTargets() {
        var viewport = ViewportTransform(imageSize: CGSize(width: 6000, height: 4000), canvasSize: CGSize(width: 900, height: 800))
        XCTAssertEqual(viewport.imageRect, CGRect(x: 0, y: 100, width: 900, height: 600))
        XCTAssertNil(viewport.normalizedPoint(at: CGPoint(x: 450, y: 99.9)))
        XCTAssertEqual(viewport.normalizedPoint(at: CGPoint(x: 900, y: 700)), CGPoint(x: 1, y: 1))
        let focal = CGPoint(x: 350, y: 350)
        let before = viewport.normalizedPoint(at: focal)!
        viewport.zoom(by: 4, around: focal)
        let after = viewport.normalizedPoint(at: focal)!
        XCTAssertEqual(before.x, after.x, accuracy: 1e-14)
        XCTAssertEqual(before.y, after.y, accuracy: 1e-14)
        XCTAssertEqual(viewport.zoomFactor, 4, accuracy: 1e-12)
        viewport.zoom(by: 100, around: focal)
        XCTAssertEqual(viewport.zoomFactor, 32, accuracy: 1e-12)
        let center = viewport.normalizedPoint(at: CGPoint(x: 450, y: 400))!
        let sourceScale = viewport.scale
        viewport.resize(to: CGSize(width: 1200, height: 600))
        let resizedCenter = viewport.normalizedPoint(at: CGPoint(x: 600, y: 300))!
        XCTAssertEqual(viewport.scale, sourceScale, accuracy: 1e-14)
        XCTAssertEqual(center.x, resizedCenter.x, accuracy: 1e-14)
        XCTAssertEqual(center.y, resizedCenter.y, accuracy: 1e-14)
        viewport.fit()
        XCTAssertEqual(viewport.zoomFactor, 1, accuracy: 1e-12)
        viewport.pan(by: CGPoint(x: -1000, y: 1000))
        XCTAssertEqual(viewport.imageRect, CGRect(x: -300, y: 300, width: 900, height: 600))
        XCTAssertNil(viewport.normalizedPoint(at: CGPoint(x: 601, y: 299)))
        let a = Marker(x: 0.5, y: 0.5), b = Marker(x: 0.5, y: 0.5)
        let point = viewport.screenPoint(x: a.x, y: a.y)
        XCTAssertEqual(viewport.nearestMarker(at: point, markers: [a, b], radius: 12), a.id)
        XCTAssertNil(viewport.nearestMarker(at: CGPoint(x: point.x + 12.01, y: point.y), markers: [a, b], radius: 12))
        XCTAssertEqual(viewport.nearestMarker(at: CGPoint(x: point.x + 12, y: point.y), markers: [a, b], radius: 12), a.id)
    }
    func testEveryEdgeAndCornerReachesClearCenterWithBlankSurroundAndSurvivesResize() {
        let source = CGSize(width: 1300, height: 813)
        let points: [CGPoint] = [.zero, CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0),
            CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1),
            CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0.5)]
        for size in [CGSize(width: 320, height: 480), CGSize(width: 1000, height: 700), CGSize(width: 600, height: 250)] {
            let clear = CGRect(x: 12, y: 90, width: size.width - 24, height: size.height - 130)
            for point in points {
                var v = ViewportTransform(imageSize: source, canvasSize: size)
                v.resize(to: size, workingRect: clear)
                v.zoom(by: 3, around: CGPoint(x: clear.midX, y: clear.midY))
                let screen = v.screenPoint(x: Double(point.x), y: Double(point.y))
                v.pan(by: CGPoint(x: clear.midX - screen.x, y: clear.midY - screen.y))
                let centered = v.screenPoint(x: Double(point.x), y: Double(point.y))
                XCTAssertEqual(centered.x, clear.midX, accuracy: 1e-9)
                XCTAssertEqual(centered.y, clear.midY, accuracy: 1e-9)
                let mapped = v.normalizedPoint(at: centered)!
                XCTAssertEqual(mapped.x, point.x, accuracy: 1e-12)
                XCTAssertEqual(mapped.y, point.y, accuracy: 1e-12)
                let blank = CGPoint(x: v.imageRect.minX - 0.01, y: v.imageRect.midY)
                XCTAssertNil(v.normalizedPoint(at: blank))
                let scale = v.scale
                v.pan(by: .zero) // release must never snap a border back under chrome
                v.resize(to: CGSize(width: size.width + 70, height: size.height + 30),
                         workingRect: clear.offsetBy(dx: 35, dy: 15))
                XCTAssertEqual(v.scale, scale, accuracy: 1e-12)
                let after = v.screenPoint(x: Double(point.x), y: Double(point.y))
                XCTAssertEqual(after.x, v.workingRect.midX, accuracy: 1e-9)
                XCTAssertEqual(after.y, v.workingRect.midY, accuracy: 1e-9)
                v.fit()
                XCTAssertEqual(v.zoomFactor, 1, accuracy: 1e-12)
                XCTAssertTrue(CGRect(origin: .zero, size: v.canvasSize).insetBy(dx: -0.001, dy: -0.001).contains(v.imageRect))
            }
        }
    }

    func testReservedFoldAndAsymmetricCameraGeometryKeepsEvidenceContiguous() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let fold = CGRect(x: 480, y: 0, width: 40, height: 800)
        let r = WorkspaceRegions(bounds: bounds, divisions: [fold], occlusions: [])
        XCTAssertEqual(r.canvas, CGRect(x: 0, y: 0, width: 480, height: 800))
        XCTAssertEqual(r.controls, CGRect(x: 520, y: 0, width: 480, height: 800))
        let horizontal = WorkspaceRegions(bounds: bounds, divisions: [CGRect(x: 0, y: 380, width: 1000, height: 40)], occlusions: [])
        XCTAssertEqual(horizontal.canvas, CGRect(x: 0, y: 0, width: 1000, height: 380))
        XCTAssertEqual(horizontal.controls, CGRect(x: 0, y: 420, width: 1000, height: 380))
        let camera = CGRect(x: 0, y: 200, width: 70, height: 220)
        let c = WorkspaceRegions(bounds: bounds, divisions: [], occlusions: [camera])
        XCTAssertFalse(c.canvas.intersects(camera)); XCTAssertNil(c.controls)
        let tight = WorkspaceRegions(bounds: bounds, divisions: [CGRect(x: 190, y: 0, width: 40, height: 800)], occlusions: [])
        XCTAssertEqual(tight.canvas.minX, 230); XCTAssertNil(tight.controls)
    }

}
