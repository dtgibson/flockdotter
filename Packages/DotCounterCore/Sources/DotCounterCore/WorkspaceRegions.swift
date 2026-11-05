import CoreGraphics

/// Local geometry only: no screen, device, orientation or hinge-angle assumptions.
/// Reserved frames already include system margins. Neither evidence nor controls
/// may straddle them. The photo keeps the first usable side of an active division.
public struct WorkspaceRegions: Sendable {
    public let canvas: CGRect
    public let controls: CGRect?

    public init(bounds: CGRect, divisions: [CGRect], occlusions: [CGRect]) {
        var pieces = [bounds]
        for exclusion in divisions + occlusions {
            pieces = pieces.flatMap { Self.subtract(exclusion, from: $0) }
        }
        let usable = pieces.filter { $0.width >= 160 && $0.height >= 110 }
        let ordered = usable.sorted {
            if abs($0.minY - $1.minY) > 1 { return $0.minY < $1.minY }
            return $0.minX < $1.minX
        }
        if divisions.contains(where: { $0.intersects(bounds) }), ordered.count >= 2,
           let first = ordered.first, first.width >= 240, first.height >= 160,
           let second = ordered.dropFirst().filter({ !$0.intersects(first) }).max(by: { $0.width * $0.height < $1.width * $1.height }),
           second.width >= 240, second.height >= 160 {
            canvas = first
            controls = second
        } else {
            canvas = (usable.isEmpty ? pieces : usable).max(by: { $0.width * $0.height < $1.width * $1.height }) ?? .zero
            controls = nil
        }
    }

    private static func subtract(_ exclusion: CGRect, from rect: CGRect) -> [CGRect] {
        let cut = rect.intersection(exclusion)
        guard !cut.isNull, !cut.isEmpty else { return [rect] }
        // Candidate rectangles overlap one another, but each is entirely clear of
        // the exclusion. Choose one for a normal layout, two only across a division.
        return [
            CGRect(x: rect.minX, y: rect.minY, width: cut.minX - rect.minX, height: rect.height),
            CGRect(x: cut.maxX, y: rect.minY, width: rect.maxX - cut.maxX, height: rect.height),
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: cut.minY - rect.minY),
            CGRect(x: rect.minX, y: cut.maxY, width: rect.width, height: rect.maxY - cut.maxY)
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
