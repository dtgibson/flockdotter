import Foundation

/// The byte stream, rather than mutable provider metadata, enforces the limit.
public enum BoundedFileReader {
    public static func read(_ url: URL, maximumBytes: Int) throws -> Data {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        return try read(maximumBytes: maximumBytes) { try input.read(upToCount: $0) }
    }

    static func read(maximumBytes: Int, next: (Int) throws -> Data?) throws -> Data {
        guard maximumBytes >= 0, maximumBytes < Int.max else { throw CocoaError(.fileReadTooLarge) }
        var result = Data()
        while true {
            try Task.checkCancellation()
            // One sentinel byte detects growth beyond the ceiling without
            // allocating or consuming an unbounded provider result.
            let requested = min(64 * 1024, maximumBytes - result.count + 1)
            guard let chunk = try next(requested), !chunk.isEmpty else { return result }
            try Task.checkCancellation()
            guard chunk.count <= maximumBytes - result.count else { throw CocoaError(.fileReadTooLarge) }
            result.append(chunk)
        }
    }
}
