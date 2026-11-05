import Foundation
import CoreGraphics
import ImageIO
import CryptoKit
import UniformTypeIdentifiers
import Darwin

public struct ImageCandidate: @unchecked Sendable {
    public let sourceURL: URL
    public let identity: ImageIdentity
    public let preview: CGImage
    public let owner: TransientDirectory?
    public init(sourceURL: URL, identity: ImageIdentity, preview: CGImage, owner: TransientDirectory? = nil) {
        self.sourceURL = sourceURL; self.identity = identity; self.preview = preview; self.owner = owner
    }
}

public enum ImageServiceError: LocalizedError, Sendable {
    case unreadable(String), unsupported, resources(String), cannotEncode, destinationExists
    public var errorDescription: String? {
        switch self {
        case .unreadable(let detail): "The photo could not be read. \(detail)"
        case .unsupported: "Choose a still JPEG, PNG or HEIC photo."
        case .resources(let detail): "This photo exceeds available resources. \(detail)"
        case .cannotEncode: "The full-resolution PNG could not be generated. Try again."
        case .destinationExists: "A file already exists at that destination. Choose a new filename."
        }
    }
}

public enum ImageService {
    public static let maxSourceBytes: UInt64 = 256 * 1024 * 1024

    private static func background<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated) {
            try await ImageWorkExecutor.shared.run(operation)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    /// Copies before hashing/decoding. No future operation depends on the provider URL.
    public static func prepare(url: URL, filename: String? = nil) async throws -> ImageCandidate {
        try await background {
            let owner = try TransientDirectory()
            let own = owner.url.appendingPathComponent(UUID().uuidString + ".blob")
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var copyResult: Result<String, any Error>?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                    copyResult = Result { try copyAndHash(from: readable, to: own) }
                }
                if let coordinationError { throw coordinationError }
                guard let copyResult else { throw ImageServiceError.unreadable("The photo provider did not provide a readable file.") }
                let hash = try copyResult.get()
                let inspected = try inspect(url: own, hash: hash, filename: filename ?? url.lastPathComponent)
                return ImageCandidate(sourceURL: own, identity: inspected.identity, preview: inspected.preview, owner: owner)
            } catch {
                try? FileManager.default.removeItem(at: own)
                throw error
            }
        }
    }

    /// Used by recovery on an app-owned immutable source. Verifies complete bytes.
    public static func inspectExisting(url: URL, filename: String) async throws -> ImageCandidate {
        try await background {
            try inspect(url: url, hash: hashFile(url), filename: filename)
        }
    }

    public static func preview(sourceURL: URL, maxPixel: Int = 4096) async throws -> CGImage {
        try await background {
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ImageServiceError.unreadable("The retained photo is unavailable.")
            }
            return try thumbnail(source: source, maxPixel: maxPixel)
        }
    }

    static func inspect(url: URL, hash: String, filename: String) throws -> ImageCandidate {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type) else {
            throw ImageServiceError.unsupported
        }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let rw = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let rh = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            throw ImageServiceError.unreadable("Image dimensions are missing.")
        }
        let width = rw.intValue, height = rh.intValue
        try checkDimensions(width: width, height: height)
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation) else { throw ImageServiceError.unreadable("Unsupported photo orientation.") }
        let rotated = orientation >= 5
        let hint = filename.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? "Photo"
        let cleanHint = hint.replacingOccurrences(of: "\0", with: "").isEmpty ? "Photo" : hint.replacingOccurrences(of: "\0", with: "")
        let identity = ImageIdentity(sha256: hash, pixelWidth: rotated ? height : width,
                                     pixelHeight: rotated ? width : height, originalFilename: cleanHint)
        try identity.validate()
        return ImageCandidate(sourceURL: url, identity: identity, preview: try thumbnail(source: source, maxPixel: 4096))
    }

    static func thumbnail(source: CGImageSource, maxPixel: Int) throws -> CGImage {
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: max(1, min(maxPixel, ResourceLimits.maxImageDimension)),
                                       kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, CGImageSourceGetPrimaryImageIndex(source), options as CFDictionary) else {
            throw ImageServiceError.unreadable("Image decoding failed. Choose another photo.")
        }
        try Task.checkCancellation()
        return image
    }

    static func checkDimensions(width: Int, height: Int) throws {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, width <= ResourceLimits.maxImageDimension,
              height <= ResourceLimits.maxImageDimension, !overflow, pixels <= ResourceLimits.maxImagePixels else {
            throw ImageServiceError.resources("Supported photos contain up to 64 million pixels, with neither edge above 32,768 pixels.")
        }
    }

    public static func hashFile(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256(), total: UInt64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            total += UInt64(data.count)
            guard total <= maxSourceBytes else { throw ImageServiceError.resources("The original file must be 256 MB or smaller.") }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// O_EXCL enforces the no-overwrite contract even if another writer races us.
    @discardableResult
    public static func copyAndHash(from: URL, to: URL) throws -> String {
        try copyAndHash(from: from, to: to, maximumBytes: maxSourceBytes)
    }

    static func copyAndHash(from: URL, to: URL, maximumBytes: UInt64) throws -> String {
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        let fd = Darwin.open(to.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            if errno == EEXIST { throw ImageServiceError.destinationExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var complete = false
        defer {
            try? output.close()
            if !complete { try? FileManager.default.removeItem(at: to) }
        }
        var hash = SHA256(), total: UInt64 = 0
        while let data = try input.read(upToCount: Int(min(1024 * 1024, maximumBytes - total + 1))), !data.isEmpty {
            try Task.checkCancellation()
            total += UInt64(data.count)
            guard total <= maximumBytes else { throw ImageServiceError.resources("The original file must be 256 MB or smaller.") }
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        try output.synchronize()
        try output.close()
        complete = true
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func noClobberCopy(from: URL, to: URL) async throws {
        _ = try await background { try copyAndHash(from: from, to: to) }
    }

    /// Maps raw top-left source coordinates into the authoritative upright frame.
    public static func orientationTransform(_ orientation: Int, width: CGFloat, height: CGFloat) -> CGAffineTransform {
        switch orientation {
        case 2: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: width, ty: 0)
        case 3: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 4: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
        case 5: CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 6: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: height, ty: 0)
        case 7: CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: height, ty: width)
        case 8: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default: .identity
        }
    }

    public static func renderPNG(sourceURL: URL, document: CountDocument, directory: URL? = nil,
                                 appearance: MarkerAppearance = .defaultAppearance,
                                 connections: ConnectionPresentation = .hidden) async throws -> URL {
        try await background {
            try document.validate()
            guard try hashFile(sourceURL) == document.image.sha256 else { throw ImageServiceError.unreadable("The retained original has changed.") }
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ImageServiceError.unreadable("The retained original is unavailable.")
            }
            let index = CGImageSourceGetPrimaryImageIndex(source)
            guard let raw = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ImageServiceError.unreadable("Full-resolution decoding failed.")
            }
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let width = document.image.pixelWidth, height = document.image.pixelHeight
            try checkDimensions(width: width, height: height)
            guard (orientation >= 5 ? raw.height : raw.width) == width,
                  (orientation >= 5 ? raw.width : raw.height) == height else { throw ImageServiceError.unreadable("The original dimensions no longer match.") }
            let font = max(12, CGFloat(min(width, height))/160)
            if appearance.style == .numberedPins, !document.markers.isEmpty {
                let minimum = MarkerRenderer.minimumBoundsForLabel(maximum: document.markers.count, fontSize: font)
                guard CGFloat(width) >= minimum.width, CGFloat(height) >= minimum.height else {
                    throw ImageServiceError.resources("The photo is too small to fit complete numbered labels. Export editable JSON or use a larger original photo.")
                }
            }
            let color = CGColorSpace(name: CGColorSpace.sRGB)!
            guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width*4, space: color,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw ImageServiceError.resources("A full-resolution output surface could not be allocated.")
            }
            ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: 1, y: -1)
            ctx.saveGState()
            ctx.concatenate(orientationTransform(orientation, width: CGFloat(raw.width), height: CGFloat(raw.height)))
            ctx.translateBy(x: 0, y: CGFloat(raw.height)); ctx.scaleBy(x: 1, y: -1)
            ctx.draw(raw, in: CGRect(x: 0, y: 0, width: raw.width, height: raw.height))
            ctx.restoreGState()
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            try ConnectionRenderer.draw(context: ctx, markers: document.markers, bounds: bounds,
                                        presentation: connections, fontSize: font,
                                        center: { CGPoint(x: $0.x * Double(width), y: $0.y * Double(height)) },
                                        checkCancellation: { try Task.checkCancellation() })
            for (index, marker) in document.markers.enumerated() {
                try Task.checkCancellation()
                MarkerRenderer.draw(context: ctx, label: index+1,
                                    center: CGPoint(x: marker.x * Double(width), y: marker.y * Double(height)),
                                    bounds: bounds, fontSize: font, appearance: appearance)
            }
            guard let result = ctx.makeImage() else { throw ImageServiceError.cannotEncode }
            let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-Exports", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let output = dir.appendingPathComponent(UUID().uuidString + ".png")
            guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw ImageServiceError.cannotEncode }
            CGImageDestinationAddImage(destination, result, [kCGImagePropertyOrientation: 1] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: output); throw ImageServiceError.cannotEncode }
            if Task.isCancelled { try? FileManager.default.removeItem(at: output); throw CancellationError() }
            return output
        }
    }
}

/// Large decodes and output surfaces are serialized, even when separate UI
/// requests overlap. Called only from an explicitly detached background task.
private actor ImageWorkExecutor {
    static let shared = ImageWorkExecutor()
    func run<T: Sendable>(_ operation: @Sendable () throws -> T) throws -> T {
        try Task.checkCancellation()
        return try operation()
    }
}
