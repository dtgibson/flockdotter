import XCTest
import CoreGraphics
import CoreText
@testable import DotCounterCore

final class MarkerAppearanceTests: XCTestCase {
    func testIndependentDefaultsFallbackAndValidChoices() {
        let suite = "MarkerAppearance-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // No app domain is ever used by this test.
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(MarkerAppearance.resolve(defaults: defaults), .defaultAppearance)
        defaults.set("coral", forKey: MarkerAppearance.colorKey)
        for invalid: Any in ["future", 42, true, ["numberedPins"]] {
            defaults.set(invalid, forKey: MarkerAppearance.styleKey)
            XCTAssertEqual(MarkerAppearance.resolve(defaults: defaults), MarkerAppearance(style: .numberedDots, color: .coral))
        }
        for style in MarkerAppearance.Style.allCases {
            for color in MarkerAppearance.Color.allCases {
                defaults.set(style.rawValue, forKey: MarkerAppearance.styleKey)
                defaults.set(color.rawValue, forKey: MarkerAppearance.colorKey)
                XCTAssertEqual(MarkerAppearance.resolve(defaults: defaults), MarkerAppearance(style: style, color: color))
            }
        }
        defaults.set("numberedPins", forKey: MarkerAppearance.styleKey)
        defaults.set(99, forKey: MarkerAppearance.colorKey)
        XCTAssertEqual(MarkerAppearance.resolve(defaults: defaults), MarkerAppearance(style: .numberedPins, color: .legacy))
    }

    func testCenteredGeometryClippingSelectionAndColorBearingTextCache() throws {
        let bounds = CGRect(x: 20, y: 20, width: 200, height: 160)
        let labels = [1, 18, 1234, 100000]
        var previous: CGFloat = 0
        for label in labels {
            let font = CTFontCreateWithName("IBMPlexMono-SemiBold" as CFString, 12, nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: String(label), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
            var ascent: CGFloat = 0, descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let diameter = MarkerRenderer.numberedDotDiameter(label: label)
            XCTAssertEqual(diameter, ceil(max(22, hypot(width, ascent+descent)+6)))
            XCTAssertGreaterThanOrEqual(diameter, previous); previous = diameter
        }
        func raster(_ style: MarkerAppearance.Style, _ color: MarkerAppearance.Color, selected: Bool = false, center: CGPoint = CGPoint(x: 120, y: 100)) throws -> [UInt8] {
            let context = try XCTUnwrap(CGContext(data: nil, width: 240, height: 200, bitsPerComponent: 8, bytesPerRow: 960,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.translateBy(x: 0, y: 200); context.scaleBy(x: 1, y: -1)
            MarkerRenderer.draw(context: context, label: 100000, center: center, bounds: bounds,
                                selected: selected, appearance: MarkerAppearance(style: style, color: color))
            return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: 240*200*4))
        }
        func alpha(_ data: [UInt8], _ x: Int, _ y: Int) -> UInt8 { data[((199-y)*240+x)*4+3] }
        for color in MarkerAppearance.Color.allCases {
            let dot = try raster(.plainDots, color), selected = try raster(.plainDots, color, selected: true)
            XCTAssertEqual(alpha(dot, 120, 100), 255)
            XCTAssertEqual(alpha(dot, 125, 100), 0, "Plain dots are exactly 8 points across")
            for y in 97...102 { for x in 117...122 {
                let i = ((199-y)*240+x)*4
                XCTAssertEqual(Array(dot[i..<i+4]), Array(selected[i..<i+4]), "Selection must preserve dot pixels")
            } }
            let edge = try raster(.plainDots, color, center: CGPoint(x: 20, y: 100))
            XCTAssertEqual(alpha(edge, 19, 100), 0); XCTAssertEqual(alpha(edge, 20, 100), 255)
            XCTAssertEqual(alpha(edge, 25, 100), 0, "Edge centers must not translate inward")
            _ = try raster(.numberedDots, color)
        }
        // Revisit navy after bright colors; CTLine cache may never reuse the wrong foreground.
        let navy = try raster(.numberedDots, .legacy), white = try raster(.numberedDots, .white)
        let navyAgain = try raster(.numberedDots, .legacy)
        XCTAssertEqual(navy, navyAgain); XCTAssertNotEqual(navy, white)
        var whiteGlyphPixels = 0
        for y in 94...105 { for x in 99...140 {
            let i = ((199-y)*240+x)*4
            if navy[i] > 220 && navy[i+1] > 220 && navy[i+2] > 220 { whiteGlyphPixels += 1 }
        } }
        XCTAssertGreaterThan(whiteGlyphPixels, 10, "Original numbered-dot text must be white")
        for style in [MarkerAppearance.Style.plainDots, .numberedDots] {
            let corner = try raster(style, .coral, center: CGPoint(x: 20, y: 20))
            for y in 0..<200 { for x in 0..<240 where x < 20 || y < 20 || x >= 220 || y >= 180 {
                XCTAssertEqual(alpha(corner, x, y), 0, "Both circle and glyphs clip to image bounds")
            } }
        }
        XCTAssertEqual(try raster(.numberedPins, .legacy), try raster(.numberedPins, .white))
    }
}
