import CoreGraphics

/// An open path through the current committed label order. Coordinates are supplied
/// by the caller's existing upright-photo mapping, including live drag previews.
public enum ConnectionRenderer {
    public static let underStrokeWidth: CGFloat = 2.5
    public static let coreStrokeWidth: CGFloat = 1

    public static func path(markers: [Marker], center: (Marker) -> CGPoint) -> CGPath? {
        path(markers: markers, center: center, checkCancellation: {})
    }

    /// A zero-length edge has no raster cap or ornament. Skipping it leaves its
    /// coincident center in the same open sequence without changing any other edge.
    public static func path(markers: [Marker], center: (Marker) -> CGPoint,
                            checkCancellation: () throws -> Void) rethrows -> CGPath? {
        try checkCancellation()
        guard markers.count > 1 else { return nil }
        let path = CGMutablePath()
        var previous = center(markers[0])
        path.move(to: previous)
        var hasSegment = false
        for index in 1..<markers.count {
            if index & 255 == 0 { try checkCancellation() }
            let next = center(markers[index])
            if next != previous {
                path.addLine(to: next)
                hasSegment = true
            }
            previous = next
        }
        try checkCancellation()
        return hasSegment ? path.copy() : nil
    }

    public static func draw(context: CGContext, markers: [Marker], bounds: CGRect,
                            presentation: ConnectionPresentation, fontSize: CGFloat = 12,
                            center: (Marker) -> CGPoint) {
        draw(context: context, markers: markers, bounds: bounds, presentation: presentation,
             fontSize: fontSize, center: center, checkCancellation: {})
    }

    /// Draws two complete passes so adjoining cores are never erased by a later
    /// segment's white under-stroke. fontSize is 12 screen points, or the existing
    /// full-resolution marker sizing context F in source pixels for PNG output.
    public static func draw(context: CGContext, markers: [Marker], bounds: CGRect,
                            presentation: ConnectionPresentation, fontSize: CGFloat = 12,
                            center: (Marker) -> CGPoint,
                            checkCancellation: () throws -> Void) rethrows {
        guard presentation.isVisible,
              let path = try path(markers: markers, center: center, checkCancellation: checkCancellation) else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        context.setAlpha(1)
        context.setLineDash(phase: 0, lengths: [])
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let scale = fontSize / 12
        context.setStrokeColor(MarkerAppearance.Color.white.fill)
        context.setLineWidth(underStrokeWidth * scale)
        context.addPath(path)
        context.strokePath()
        try checkCancellation()
        context.setStrokeColor(MarkerAppearance.Color.legacy.fill)
        context.setLineWidth(coreStrokeWidth * scale)
        context.addPath(path)
        context.strokePath()
    }
}
