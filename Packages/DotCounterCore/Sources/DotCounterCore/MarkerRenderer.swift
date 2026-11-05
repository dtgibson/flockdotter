import CoreGraphics
import CoreText
import Foundation

/// Draws in a top-left, downward-positive coordinate system. Label sizes are
/// screen points on the canvas and source pixels in an annotated export.
public enum MarkerRenderer {
    private static let layouts = MarkerLayoutCache()

    public static func minimumBoundsForLabel(maximum: Int, fontSize: CGFloat) -> CGSize {
        let sample = String(repeating: "8", count: String(maximum).count)
        let layout = layouts.layout(text: sample, fontSize: fontSize)
        let padding = max(3, fontSize * 0.27), inset = max(1, fontSize / 12)
        return CGSize(width: layout.width + 2*padding + 2*inset, height: layout.ascent + layout.descent + 2*padding + 2*inset)
    }

    public static func numberedDotDiameter(label: Int, fontSize: CGFloat = 12) -> CGFloat {
        let layout = layouts.layout(text: String(label), fontSize: fontSize)
        return diameter(layout: layout, fontSize: fontSize)
    }

    private static func diameter(layout: MarkerTextLayout, fontSize: CGFloat) -> CGFloat {
        ceil(max(22 * fontSize/12, hypot(layout.width, layout.ascent+layout.descent) + fontSize/2))
    }

    private static func drawCenteredSelection(_ context: CGContext, center: CGPoint, side: CGFloat) {
        let square = CGRect(x: center.x-side/2, y: center.y-side/2, width: side, height: side)
        context.setLineDash(phase: 0, lengths: [3, 2])
        context.setLineWidth(3); context.setStrokeColor(MarkerLayoutCache.white); context.stroke(square)
        context.setLineWidth(1.5); context.setStrokeColor(MarkerLayoutCache.navy); context.stroke(square)
        context.setLineDash(phase: 0, lengths: [])
    }

    public static func draw(context: CGContext, label: Int, center: CGPoint,
                            bounds: CGRect, fontSize: CGFloat = 12, selected: Bool = false,
                            appearance: MarkerAppearance = .defaultAppearance) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        if appearance.style == .plainDots {
            let radius = fontSize / 3
            context.setFillColor(appearance.color.fill)
            context.fillEllipse(in: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
            if selected { drawCenteredSelection(context, center: center, side: 20) }
            return
        }
        if appearance.style == .numberedDots {
            let whiteText = appearance.color == .legacy
            let layout = layouts.layout(text: String(label), fontSize: fontSize, whiteText: whiteText)
            let diameter = diameter(layout: layout, fontSize: fontSize)
            let circle = CGRect(x: center.x-diameter/2, y: center.y-diameter/2, width: diameter, height: diameter)
            context.setFillColor(appearance.color.fill)
            context.setStrokeColor(whiteText ? MarkerLayoutCache.white : MarkerLayoutCache.navy)
            context.setLineWidth(max(1, fontSize/12))
            context.addEllipse(in: circle); context.drawPath(using: .fillStroke)
            if selected { drawCenteredSelection(context, center: center, side: diameter+8) }
            context.translateBy(x: center.x-layout.width/2, y: center.y+(layout.ascent-layout.descent)/2)
            context.scaleBy(x: 1, y: -1); context.textPosition = .zero
            CTLineDraw(layout.line, context)
            return
        }
        let layout = layouts.layout(text: String(label), fontSize: fontSize)
        let navy = MarkerLayoutCache.navy
        let padding = max(3, fontSize * 0.27)
        let boxSize = CGSize(width: layout.width + 2 * padding, height: layout.ascent + layout.descent + 2 * padding)
        let inset = max(1, fontSize / 12)
        let valid = bounds.insetBy(dx: inset, dy: inset)
        let x = max(valid.minX, min(center.x + fontSize * 0.5, valid.maxX - boxSize.width))
        let y = max(valid.minY, min(center.y - boxSize.height - fontSize * 0.45, valid.maxY - boxSize.height))
        let box = CGRect(origin: CGPoint(x: x, y: y), size: boxSize)
        context.saveGState()
        context.setLineWidth(max(1, fontSize / 12))
        context.setStrokeColor(navy)
        context.move(to: center)
        context.addLine(to: CGPoint(x: max(box.minX, min(center.x, box.maxX)), y: box.maxY))
        context.strokePath()
        context.setFillColor(appearance.color == .legacy ? MarkerLayoutCache.white : appearance.color.fill)
        context.addPath(CGPath(roundedRect: box, cornerWidth: fontSize / 3, cornerHeight: fontSize / 3, transform: nil))
        context.drawPath(using: .fillStroke)
        let radius = max(2.5, fontSize / 4)
        context.setLineWidth(max(1.3, fontSize / 9))
        context.setStrokeColor(appearance.color == .legacy ? MarkerLayoutCache.white : appearance.color.fill)
        context.strokeEllipse(in: CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2))
        context.setLineWidth(max(0.6, fontSize / 18))
        context.setStrokeColor(navy)
        context.strokeEllipse(in: CGRect(x: center.x-radius-1, y: center.y-radius-1, width: radius*2+2, height: radius*2+2))
        if selected {
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [3, 2])
            context.stroke(CGRect(x: center.x-9, y: center.y-9, width: 18, height: 18))
            context.setLineDash(phase: 0, lengths: [])
        }
        context.translateBy(x: box.minX + padding, y: box.minY + padding + layout.ascent)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        CTLineDraw(layout.line, context)
        context.restoreGState()
    }
}

/// Immutable Core Text layouts can be shared by independent canvas/export
/// contexts. No marker bitmap is cached, and memory remains bounded when label
/// counts, Dynamic Type sizes, or export sizes vary.
private final class MarkerTextLayout: NSObject, @unchecked Sendable {
    let line: CTLine
    let width: CGFloat
    let ascent: CGFloat
    let descent: CGFloat

    init(text: String, font: CTFont, whiteText: Bool) {
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): whiteText ? MarkerLayoutCache.white : MarkerLayoutCache.navy
        ])
        line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        self.ascent = ascent; self.descent = descent
    }
}

private final class MarkerFont: NSObject {
    let font: CTFont
    init(size: CGFloat) { font = CTFontCreateWithName("IBMPlexMono-SemiBold" as CFString, size, nil) }
}

/// NSCache may evict under memory pressure. The lock protects the complete
/// lookup/create/store operation, including the separate bounded font cache.
private final class MarkerLayoutCache: @unchecked Sendable {
    static let navy = CGColor(red: 25/255, green: 58/255, blue: 74/255, alpha: 1)
    static let white = CGColor(gray: 1, alpha: 1)
    private let lock = NSLock()
    private let labels = NSCache<NSString, MarkerTextLayout>()
    private let fonts = NSCache<NSString, MarkerFont>()

    init() {
        labels.countLimit = 4096
        fonts.countLimit = 32
    }

    func layout(text: String, fontSize: CGFloat, whiteText: Bool = false) -> MarkerTextLayout {
        let size = fontSize.isFinite && fontSize > 0 ? fontSize : 12
        let fontKey = String(Double(size).bitPattern) as NSString
        let labelKey = "\(fontKey):\(whiteText):\(text)" as NSString
        lock.lock(); defer { lock.unlock() }
        if let cached = labels.object(forKey: labelKey) { return cached }
        let font: MarkerFont
        if let existing = fonts.object(forKey: fontKey) { font = existing }
        else {
            font = MarkerFont(size: size)
            fonts.setObject(font, forKey: fontKey)
        }
        let layout = MarkerTextLayout(text: text, font: font.font, whiteText: whiteText)
        labels.setObject(layout, forKey: labelKey)
        return layout
    }
}
