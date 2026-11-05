import Foundation
import CoreGraphics

/// Image and canvas coordinates use top-left origin. Normalized points are full
/// upright source-pixel fractions; marker storage never depends on viewport scale.
public struct ViewportTransform: Sendable {
    public private(set) var imageSize: CGSize
    public private(set) var canvasSize: CGSize
    public private(set) var workingRect: CGRect
    public private(set) var scale: CGFloat = 1
    public private(set) var translation: CGPoint = .zero
    public var fitScale: CGFloat {
        guard imageSize.width > 0, imageSize.height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return 1 }
        return min(canvasSize.width / imageSize.width, canvasSize.height / imageSize.height)
    }
    public var zoomFactor: CGFloat { scale / fitScale }
    public var imageRect: CGRect {
        CGRect(origin: translation, size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
    }

    public init(imageSize: CGSize, canvasSize: CGSize) {
        self.imageSize = imageSize
        self.canvasSize = canvasSize
        self.workingRect = CGRect(origin: .zero, size: canvasSize)
        fit()
    }

    public func screenPoint(x: Double, y: Double) -> CGPoint {
        CGPoint(x: translation.x + CGFloat(x) * imageSize.width * scale,
                y: translation.y + CGFloat(y) * imageSize.height * scale)
    }

    /// Inclusive edges are valid. Only machine-epsilon roundoff at exact edges is
    /// corrected; a released drag outside the photograph is never clamped inward.
    public func normalizedPoint(at point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite, scale > 0,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        let x = (point.x - translation.x) / (imageSize.width * scale)
        let y = (point.y - translation.y) / (imageSize.height * scale)
        let tolerance = CGFloat.ulpOfOne * 8
        guard x >= -tolerance, x <= 1 + tolerance, y >= -tolerance, y <= 1 + tolerance else { return nil }
        return CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    public mutating func fit() {
        scale = fitScale
        translation = CGPoint(x: (canvasSize.width - imageSize.width * scale) / 2,
                              y: (canvasSize.height - imageSize.height * scale) / 2)
        clamp()
    }
    /// Inspection may center a border bird with surrounding canvas visible.
    public mutating func focus(x:Double,y:Double,sourceScale:CGFloat) {
        guard x.isFinite,y.isFinite,sourceScale.isFinite,sourceScale>0 else{return}
        scale=min(max(fitScale,sourceScale),max(fitScale*32,5))
        translation=CGPoint(x:workingRect.midX-CGFloat(x)*imageSize.width*scale,y:workingRect.midY-CGFloat(y)*imageSize.height*scale)
        clamp()
    }

    public mutating func pan(by delta: CGPoint) {
        guard delta.x.isFinite, delta.y.isFinite else { return }
        translation.x += delta.x
        translation.y += delta.y
        clamp()
    }

    public mutating func zoom(by factor: CGFloat, around focal: CGPoint) {
        guard factor.isFinite, factor > 0, focal.x.isFinite, focal.y.isFinite else { return }
        let next = min(fitScale * 32, max(fitScale, scale * factor))
        let ratio = next / scale
        translation = CGPoint(x: focal.x - (focal.x - translation.x) * ratio,
                              y: focal.y - (focal.y - translation.y) * ratio)
        scale = next
        clamp()
    }

    /// Keep the same source point in the clear working area's center and keep
    /// source scale, even when a fold or floating controls change its geometry.
    public mutating func resize(to size: CGSize, workingRect proposed: CGRect? = nil) {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return }
        let bounds = CGRect(origin: .zero, size: size)
        let intersection = (proposed ?? bounds).intersection(bounds)
        let nextWorking = intersection.isNull || intersection.isEmpty ? bounds : intersection
        guard size != canvasSize || nextWorking != workingRect else { return }
        let source = CGPoint(x: (workingRect.midX - translation.x) / scale,
                             y: (workingRect.midY - translation.y) / scale)
        let previousScale = scale
        let wasEmpty = canvasSize.width <= 0 || canvasSize.height <= 0
        canvasSize = size
        workingRect = nextWorking
        if wasEmpty { fit(); return }
        scale = min(max(fitScale, previousScale), max(fitScale * 32, 5))
        translation = CGPoint(x: workingRect.midX - source.x * scale,
                              y: workingRect.midY - source.y * scale)
        clamp()
    }

    /// Reveal a selected marker without changing the user's zoom or moving a
    /// marker that is already clear of chrome.
    public mutating func reveal(x: Double, y: Double, margin: CGFloat = 24) {
        let point = screenPoint(x: x, y: y)
        let inset = min(margin, min(workingRect.width, workingRect.height) / 4)
        if !workingRect.insetBy(dx: inset, dy: inset).contains(point) {
            translation.x += workingRect.midX - point.x
            translation.y += workingRect.midY - point.y
            clamp()
        }
    }

    public func nearestMarker(at point: CGPoint, markers: [Marker], radius: CGFloat) -> UUID? {
        guard radius >= 0 else { return nil }
        var bestDistance = radius * radius
        var selected: UUID?
        for marker in markers {
            let center = screenPoint(x: marker.x, y: marker.y)
            let dx = point.x - center.x, dy = point.y - center.y
            let distance = dx * dx + dy * dy
            if distance <= bestDistance && (selected == nil || distance < bestDistance) {
                selected = marker.id
                bestDistance = distance
            }
        }
        return selected
    }

    private mutating func clamp() {
        let width = imageSize.width * scale, height = imageSize.height * scale
        // Each source edge may reach the clear center. Blank surround is deliberate;
        // a covering-image clamp would trap edge birds beneath floating controls.
        translation.x = min(workingRect.midX, max(workingRect.midX - width, translation.x))
        translation.y = min(workingRect.midY, max(workingRect.midY - height, translation.y))
    }
}
