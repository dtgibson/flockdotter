import Foundation
import CryptoKit

public enum ResourceLimits {
    public static let maxImagePixels = 64_000_000
    public static let maxImageDimension = 32_768
    public static let maxMarkers = 100_000
    public static let maxJSONBytes = 32 * 1024 * 1024
}

public enum CountError: LocalizedError, Equatable, Sendable {
    case invalid(String)
    case unsupportedVersion
    case resource(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let detail): "This marker file can’t be opened. \(detail)"
        case .unsupportedVersion: "This marker file uses an unsupported format or version."
        case .resource(let detail): "This file needs more resources than DotCounter supports. \(detail)"
        }
    }
}

public struct Marker: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var x: Double
    public var y: Double

    public init(id: UUID = UUID(), x: Double, y: Double) {
        self.id = id
        self.x = x == 0 ? 0 : x
        self.y = y == 0 ? 0 : y
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id),
                  x: try container.decode(Double.self, forKey: .x),
                  y: try container.decode(Double.self, forKey: .y))
        try validate()
    }

    public func validate() throws {
        guard x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw CountError.invalid("Marker coordinates must be finite numbers from 0 through 1.")
        }
    }
}

public struct ImageIdentity: Codable, Equatable, Sendable {
    public var sha256: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var originalFilename: String

    public init(sha256: String, pixelWidth: Int, pixelHeight: Int, originalFilename: String) {
        self.sha256 = sha256
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.originalFilename = originalFilename
    }

    public func validate() throws {
        guard Self.isDigest(sha256) else { throw CountError.invalid("The photo fingerprint is invalid.") }
        guard pixelWidth > 0, pixelHeight > 0 else { throw CountError.invalid("Photo dimensions must be positive integers.") }
        let (pixels, overflow) = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !overflow, pixelWidth <= ResourceLimits.maxImageDimension,
              pixelHeight <= ResourceLimits.maxImageDimension, pixels <= ResourceLimits.maxImagePixels else {
            throw CountError.resource("Choose a photo no larger than 64 megapixels and 32,768 pixels per side.")
        }
        guard !originalFilename.isEmpty, originalFilename.utf8.count <= 1024,
              !originalFilename.contains("/"), !originalFilename.contains("\\"),
              !originalFilename.contains("\0"), originalFilename != ".", originalFilename != ".." else {
            throw CountError.invalid("The original-photo hint must be a filename without a folder path.")
        }
    }

    public func matches(_ other: ImageIdentity) -> Bool {
        sha256 == other.sha256 && pixelWidth == other.pixelWidth && pixelHeight == other.pixelHeight
    }

    public static func isDigest(_ string: String) -> Bool {
        string.utf8.count == 64 && string.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct CountDocument: Codable, Equatable, Sendable {
    public var format: String
    public var version: Int
    public var image: ImageIdentity
    public var markers: [Marker]
    public var total: Int { markers.count }

    public init(image: ImageIdentity, markers: [Marker] = []) {
        format = "dotcounter"
        version = 1
        self.image = image
        self.markers = markers
    }

    public func validate() throws {
        guard format == "dotcounter", version == 1 else { throw CountError.unsupportedVersion }
        try image.validate()
        guard markers.count <= ResourceLimits.maxMarkers else {
            throw CountError.resource("A count can contain up to 100,000 markers.")
        }
        var seen = Set<UUID>()
        for marker in markers {
            try marker.validate()
            guard seen.insert(marker.id).inserted else { throw CountError.invalid("Marker identities must be unique.") }
        }
    }

    public func validated() throws -> CountDocument { try validate(); return self }

    public static func decode(_ data: Data) throws -> CountDocument {
        try StrictCountJSON.decode(data)
    }

    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Canonical v1 digest: length-prefixed UTF-8 identity fields, then each lowercase
    /// UUID and normalized IEEE-754 coordinate bits. Integers are big-endian UInt64.
    public var contentDigest: String {
        var data = Data("dotcounter-content-v1".utf8)
        func appendInteger(_ value: UInt64) {
            var big = value.bigEndian
            withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
        }
        func appendString(_ value: String) {
            let bytes = Array(value.utf8)
            appendInteger(UInt64(bytes.count))
            data.append(contentsOf: bytes)
        }
        appendString(image.sha256)
        appendInteger(UInt64(max(0, image.pixelWidth)))
        appendInteger(UInt64(max(0, image.pixelHeight)))
        appendString(image.originalFilename)
        appendInteger(UInt64(markers.count))
        for marker in markers {
            appendString(marker.id.uuidString.lowercased())
            appendInteger((marker.x == 0 ? 0.0 : marker.x).bitPattern)
            appendInteger((marker.y == 0 ? 0.0 : marker.y).bitPattern)
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
