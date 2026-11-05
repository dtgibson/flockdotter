import XCTest
import CoreGraphics
@testable import DotCounterCore

final class ConnectionRendererTests: XCTestCase {
    func testVisibilityDefaultsAreTypedAndIndependentOfAppearance() {
        let suite = "ConnectionPresentation-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("plainDots", forKey: MarkerAppearance.styleKey)
        defaults.set("coral", forKey: MarkerAppearance.colorKey)
        XCTAssertEqual(ConnectionPresentation.resolve(defaults: defaults), .hidden)
        for invalid: Any in [true, 1, "future", ["shown"]] {
            defaults.set(invalid, forKey: ConnectionPresentation.visibilityKey)
            XCTAssertEqual(ConnectionPresentation.resolve(defaults: defaults), .hidden)
        }
        for value in [ConnectionPresentation.hidden, .shown] {
            defaults.set(value.storageValue, forKey: ConnectionPresentation.visibilityKey)
            XCTAssertEqual(ConnectionPresentation.resolve(defaults: defaults), value)
            XCTAssertEqual(MarkerAppearance.resolve(defaults: defaults), MarkerAppearance(style: .plainDots, color: .coral))
        }
        // Resetting either appearance key cannot erase the connection choice.
        defaults.set(MarkerAppearance.defaultAppearance.style.rawValue, forKey: MarkerAppearance.styleKey)
        defaults.set(MarkerAppearance.defaultAppearance.color.rawValue, forKey: MarkerAppearance.colorKey)
        XCTAssertEqual(ConnectionPresentation.resolve(defaults: defaults), .shown)
    }

    func testOpenTopologyUsesSuppliedCentersAndHasNoCoincidentOrClosingEdge() throws {
        let markers = [Marker(x: 0.1, y: 0.2), Marker(x: 0.1, y: 0.2),
                       Marker(x: 0.8, y: 0.2), Marker(x: 0.8, y: 0.9)]
        let moving = markers[2].id
        let path = try XCTUnwrap(ConnectionRenderer.path(markers: markers) {
            $0.id == moving ? CGPoint(x: 70, y: 30) : CGPoint(x: $0.x*100, y: $0.y*100)
        })
        var types: [CGPathElementType] = [], points: [CGPoint] = []
        path.applyWithBlock { element in
            types.append(element.pointee.type)
            if element.pointee.type != .closeSubpath { points.append(element.pointee.points[0]) }
        }
        XCTAssertEqual(types, [.moveToPoint, .addLineToPoint, .addLineToPoint])
        XCTAssertEqual(points, [CGPoint(x: 10, y: 20), CGPoint(x: 70, y: 30), CGPoint(x: 80, y: 90)])
        XCTAssertNil(ConnectionRenderer.path(markers: [], center: { _ in .zero }))
        XCTAssertNil(ConnectionRenderer.path(markers: [markers[0]], center: { _ in .zero }))
        XCTAssertNil(ConnectionRenderer.path(markers: markers, center: { _ in .zero }))
    }

    func testClippingTwoToneScalingAndCancellationBeforeDrawing() throws {
        let width = 120, height = 120
        let bounds = CGRect(x: 20, y: 20, width: 80, height: 80)
        let markers = [Marker(x: 0.1, y: 0.4), Marker(x: 0.9, y: 0.4), Marker(x: 0.9, y: 0.9)]
        func context() throws -> CGContext {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width*4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
            return context
        }
        func pixels(_ context: CGContext) -> [UInt8] {
            Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: width*height*4))
        }
        func pixel(_ data: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            let index = (y*width+x)*4
            return Array(data[index..<index+4])
        }
        let center: (Marker) -> CGPoint = { CGPoint(x: $0.x*100+0.5, y: $0.y*100+0.5) }
        let normal = try context()
        ConnectionRenderer.draw(context: normal, markers: markers, bounds: bounds, presentation: .shown, center: center)
        let data = pixels(normal)
        XCTAssertEqual(pixel(data, 50, 40), [25, 58, 74, 255], "Opaque navy core")
        let halo = pixel(data, 50, 39)
        XCTAssertGreaterThan(halo[3], 0)
        XCTAssertEqual(halo[0], halo[1]); XCTAssertEqual(halo[1], halo[2], "White under-stroke")
        XCTAssertEqual(pixel(data, 50, 42)[3], 0)
        XCTAssertEqual(pixel(data, 50, 60)[3], 0, "No last-to-first diagonal")
        XCTAssertEqual(pixel(data, 19, 40)[3], 0, "Photo clipping")
        let scaled = try context()
        ConnectionRenderer.draw(context: scaled, markers: markers, bounds: bounds, presentation: .shown,
                                fontSize: 24, center: center)
        XCTAssertGreaterThan(pixel(pixels(scaled), 50, 42)[3], 0, "Export widths scale with F/12")
        let hidden = try context()
        ConnectionRenderer.draw(context: hidden, markers: markers, bounds: bounds, presentation: .hidden, center: center)
        XCTAssertTrue(pixels(hidden).allSatisfy { $0 == 0 })
        let coincident = try context()
        ConnectionRenderer.draw(context: coincident, markers: markers, bounds: bounds, presentation: .shown,
                                center: { _ in CGPoint(x: 50, y: 50) })
        XCTAssertTrue(pixels(coincident).allSatisfy { $0 == 0 }, "No round cap on a degenerate edge")
        let canceled = try context()
        var checks = 0
        XCTAssertThrowsError(try ConnectionRenderer.draw(context: canceled,
            markers: (0..<1_000).map { Marker(x: Double($0)/1_000, y: 0.5) }, bounds: bounds,
            presentation: .shown, center: center, checkCancellation: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            }))
        XCTAssertEqual(checks, 2)
        XCTAssertTrue(pixels(canceled).allSatisfy { $0 == 0 }, "No partial path is drawn before construction completes")
    }
}
