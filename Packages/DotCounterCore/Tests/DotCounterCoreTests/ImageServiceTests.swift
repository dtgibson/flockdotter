import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit
@testable import DotCounterCore

final class ImageServiceTests: XCTestCase, @unchecked Sendable {
    func testEightOrientationsMatchKnownPixelsInPreviewAndFullPNG() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Expected upright quadrant order: top-left, top-right, bottom-left, bottom-right.
        let expected = [[0,1,2,3], [1,0,3,2], [3,2,1,0], [2,3,0,1],
                        [0,2,1,3], [2,0,3,1], [3,1,2,0], [1,3,0,2]]
        for orientation in 1...8 {
            let source = directory.appendingPathComponent("orientation-\(orientation).jpg")
            try writeFixture(source, orientation: orientation)
            let candidate = try await ImageService.prepare(url: source)
            defer { try? FileManager.default.removeItem(at: candidate.sourceURL) }
            XCTAssertEqual(candidate.identity.pixelWidth, orientation >= 5 ? 60 : 80)
            XCTAssertEqual(candidate.identity.pixelHeight, orientation >= 5 ? 80 : 60)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: candidate.sourceURL))
            XCTAssertEqual(try quadrants(candidate.preview), expected[orientation-1], "preview EXIF \(orientation)")
            let raster=try BirdSourceRaster(url:source,identity:candidate.identity)
            let tile=try BirdDetectionPolicy.roots(width:candidate.identity.pixelWidth,height:candidate.identity.pixelHeight)[0]
            let tensor=try raster.tensor(tile:tile,control:BirdScanControl())
            let w=candidate.identity.pixelWidth,h=candidate.identity.pixelHeight
            let samples=[(w/4,h/4),(3*w/4,h/4),(w/4,3*h/4),(3*w/4,3*h/4)]
            let means:[Float]=[0.485,0.456,0.406],std:[Float]=[0.229,0.224,0.225]
            for (i,p) in samples.enumerated() {
                let index=(p.1*2)*800+p.0*2
                let c=(0..<3).map{tensor[$0*640000+index].floatValue*std[$0]+means[$0]}
                let label=c[0]>0.6 && c[1]>0.6 ? 3:(c[0]>c[1] && c[0]>c[2] ? 0:(c[1]>c[2] ? 1:2))
                XCTAssertEqual(label,expected[orientation-1][i],"detector EXIF \(orientation), quadrant \(i)")
            }
            // Source-border fill is normalized black, not an unnormalized zero tensor.
            XCTAssertEqual(tensor[799*800+799].floatValue,-means[0]/std[0],accuracy:0.00001)
            let doc = CountDocument(image: candidate.identity, markers: [])
            let output = try await ImageService.renderPNG(sourceURL: candidate.sourceURL, document: doc, directory: directory)
            let resultSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
            let result = try XCTUnwrap(CGImageSourceCreateImageAtIndex(resultSource, 0, nil))
            XCTAssertEqual(result.width, candidate.identity.pixelWidth)
            XCTAssertEqual(result.height, candidate.identity.pixelHeight)
            XCTAssertEqual(try quadrants(result), expected[orientation-1], "full export EXIF \(orientation)")
            let properties = CGImageSourceCopyPropertiesAtIndex(resultSource, 0, nil) as? [CFString: Any]
            XCTAssertEqual((properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1, 1)
        }
    }

    func testSupportedFormatsOriginalIdentityAndNoClobber() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for type in [UTType.png, .jpeg, .heic] {
            let source = directory.appendingPathComponent("fixture." + (type.preferredFilenameExtension ?? "img"))
            try writeFixture(source, type: type)
            let candidate = try await ImageService.prepare(url: source, filename: "folder/../birds." + (type.preferredFilenameExtension ?? "img"))
            defer { try? FileManager.default.removeItem(at: candidate.sourceURL) }
            XCTAssertFalse(candidate.identity.originalFilename.contains("/"))
            let original = try Data(contentsOf: source)
            XCTAssertEqual(candidate.identity.sha256, SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined())
            let copy = directory.appendingPathComponent(UUID().uuidString)
            try await ImageService.noClobberCopy(from: candidate.sourceURL, to: copy)
            XCTAssertEqual(try Data(contentsOf: copy), original)
            do { try await ImageService.noClobberCopy(from: candidate.sourceURL, to: copy); XCTFail("must reject collision") }
            catch ImageServiceError.destinationExists { }
            XCTAssertEqual(try Data(contentsOf: copy), original)
        }
    }

    func testFullSize24MPExportWith1000MarkersAndEdgeLabels() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("reference.jpg")
        try writeFixture(source, width: 6000, height: 4000)
        let candidate = try await ImageService.prepare(url: source)
        defer { try? FileManager.default.removeItem(at: candidate.sourceURL) }
        let warmStart = ContinuousClock.now
        let warmed = try await ImageService.prepare(url: source)
        let warmDuration = warmStart.duration(to: .now)
        try? FileManager.default.removeItem(at: warmed.sourceURL)
        print("PERFORMANCE native macOS Debug warm24MP prepare(copy/hash/verify/upright4096preview): \(warmDuration)")
        var markers = (0..<996).map { Marker(x: Double($0 % 40)/40 + 0.01, y: Double($0 / 40)/25 + 0.01) }
        markers += [Marker(x: 0,y: 0), Marker(x: 1,y: 0), Marker(x: 0,y: 1), Marker(x: 1,y: 1)]
        let document = CountDocument(image: candidate.identity, markers: markers)
        let output = try await ImageService.renderPNG(sourceURL: candidate.sourceURL, document: document, directory: directory, appearance: MarkerAppearance(style: .numberedPins, color: .legacy))
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 6000); XCTAssertEqual(image.height, 4000)
        XCTAssertEqual(document.markers, markers)
        XCTAssertEqual(try ImageService.hashFile(candidate.sourceURL), candidate.identity.sha256)
        // Four-digit label 1000 must be drawn wholly inward near the lower-right edge.
        let pixel = try color(image, x: image.width-40, y: image.height-20)
        XCTAssertTrue(pixel.contains { $0 > 220 }, "edge label backing remains inside the raster")
        let renderMarkers = markers
        let drawSample = try await MainActor.run { () throws -> (frames: Int, max: Double, mean: Double) in
            let width = 1200, height = 800
            let ctx = try XCTUnwrap(CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                                             space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
            let start = CFAbsoluteTimeGetCurrent()
            var frames = 0, longest = 0.0, total = 0.0
            while CFAbsoluteTimeGetCurrent() - start < 10 {
                let before = CFAbsoluteTimeGetCurrent()
                ctx.clear(CGRect(x:0,y:0,width:width,height:height))
                for (i,marker) in renderMarkers.enumerated() {
                    MarkerRenderer.draw(context:ctx,label:i+1,center:CGPoint(x:marker.x*Double(width),y:marker.y*Double(height)),
                                        bounds:CGRect(x:0,y:0,width:width,height:height), appearance: MarkerAppearance(style: .numberedPins, color: .legacy))
                }
                let elapsed = CFAbsoluteTimeGetCurrent() - before
                longest = max(longest,elapsed); total += elapsed; frames += 1
            }
            return (frames,longest,total/Double(frames))
        }
        print("PERFORMANCE native macOS Debug10s MAIN offscreen1000-label full redraw: frames=\(drawSample.frames) maxMs=\(drawSample.max*1000) meanMs=\(drawSample.mean*1000). Renderer-only; not end-to-end UI stall measurement.")
    }

    func testRejectInvalidAndResourceInputsWithoutOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bad = directory.appendingPathComponent("not-a-photo.jpg")
        try Data("not an image".utf8).write(to: bad)
        do { _ = try await ImageService.prepare(url: bad); XCTFail("must reject invalid image") }
        catch { }
        XCTAssertThrowsError(try ImageService.checkDimensions(width: 32768, height: 32768))
        XCTAssertNoThrow(try ImageService.checkDimensions(width: 6000, height: 4000))
        let tiny = directory.appendingPathComponent("tiny.png")
        try writeFixture(tiny,type:.png,width:4,height:4)
        let candidate = try await ImageService.prepare(url:tiny)
        defer { try? FileManager.default.removeItem(at:candidate.sourceURL) }
        let zeroOutput = try await ImageService.renderPNG(sourceURL:candidate.sourceURL,document:CountDocument(image:candidate.identity,markers:[]),directory:directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath:zeroOutput.path))
        do {
            _ = try await ImageService.renderPNG(sourceURL:candidate.sourceURL,document:CountDocument(image:candidate.identity,markers:[Marker(x:0,y:0)]),directory:directory, appearance: MarkerAppearance(style: .numberedPins, color: .legacy))
            XCTFail("complete labels cannot fit inside4x4 pixels")
        } catch ImageServiceError.resources { }
        for style in [MarkerAppearance.Style.plainDots, .numberedDots] {
            let output = try await ImageService.renderPNG(sourceURL: candidate.sourceURL,
                document: CountDocument(image: candidate.identity, markers: [Marker(x: 0, y: 0)]),
                directory: directory, appearance: MarkerAppearance(style: style, color: .legacy))
            XCTAssertTrue(FileManager.default.fileExists(atPath: output.path), "Centered marks deliberately clip on tiny photos")
        }
    }

    func testEveryAppearancePNGMatchesSharedRendererAtCenterAndEdges() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("appearance.png")
        try writeFixture(source, type: .png, width: 160, height: 120)
        let candidate = try await ImageService.prepare(url: source)
        let document = CountDocument(image: candidate.identity, markers: [Marker(x: 0.5, y: 0.5), Marker(x: 0, y: 0), Marker(x: 1, y: 1)])
        let width = 160, height = 120, bounds = CGRect(x: 0, y: 0, width: width, height: height)
        func context() throws -> CGContext {
            try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        }
        for style in MarkerAppearance.Style.allCases {
            for color in MarkerAppearance.Color.allCases {
                for connections in [ConnectionPresentation.hidden, .shown] {
                    let appearance = MarkerAppearance(style: style, color: color)
                    let url = try await ImageService.renderPNG(sourceURL: candidate.sourceURL, document: document,
                        directory: directory, appearance: appearance, connections: connections)
                    let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
                    let actualImage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
                    let expected = try context()
                    expected.draw(candidate.preview, in: bounds)
                    expected.translateBy(x: 0, y: CGFloat(height)); expected.scaleBy(x: 1, y: -1)
                    ConnectionRenderer.draw(context: expected, markers: document.markers, bounds: bounds,
                        presentation: connections,
                        center: { CGPoint(x: $0.x*Double(width), y: $0.y*Double(height)) })
                    for (index, marker) in document.markers.enumerated() {
                        MarkerRenderer.draw(context: expected, label: index+1,
                            center: CGPoint(x: marker.x*Double(width), y: marker.y*Double(height)), bounds: bounds, appearance: appearance)
                    }
                    let actual = try context(); actual.draw(actualImage, in: bounds)
                    XCTAssertEqual(Data(bytes: actual.data!, count: width*height*4), Data(bytes: expected.data!, count: width*height*4), "\(style) / \(color) / \(connections.storageValue)")
                }
            }
        }
        XCTAssertEqual(try ImageService.hashFile(candidate.sourceURL), candidate.identity.sha256)
    }

    func temporaryDirectory() throws -> URL {
        let result = FileManager.default.temporaryDirectory.appendingPathComponent("DotCounterImageTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        return result
    }

    func writeFixture(_ url: URL, orientation: Int = 1, type: UTType = .jpeg, width: Int = 80, height: Int = 60) throws {
        let palette: [[UInt8]] = [[240,20,20,255], [20,220,20,255], [20,20,240,255], [240,220,20,255]]
        var data = Data(count: width*height*4)
        data.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let c = palette[(y >= height/2 ? 2 : 0) + (x >= width/2 ? 1 : 0)]
                let index = (y*width+x)*4
                for channel in 0..<4 { p[index+channel] = c[channel] }
            } }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                         provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination,image,[kCGImagePropertyOrientation: orientation, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    func quadrants(_ image: CGImage) throws -> [Int] {
        try [(image.width/4,image.height/4),(image.width*3/4,image.height/4),
             (image.width/4,image.height*3/4),(image.width*3/4,image.height*3/4)].map { x,y in
            let c = try color(image,x: x,y: y)
            if c[0] > 150 && c[1] > 150 { return 3 }
            if c[0] > c[1] && c[0] > c[2] { return 0 }
            if c[1] > c[0] && c[1] > c[2] { return 1 }
            return 2
        }
    }

    func color(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let ctx = try XCTUnwrap(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
                                         space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let pointer = try XCTUnwrap(ctx.data).bindMemory(to:UInt8.self,capacity:image.width*image.height*4)
        let index = (y*image.width+x)*4
        return Array(UnsafeBufferPointer(start:pointer+index,count:4))
    }
}
