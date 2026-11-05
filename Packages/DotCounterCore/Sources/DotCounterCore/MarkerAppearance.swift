import Foundation
import CoreGraphics

/// Installation-local presentation only; never part of a count or recovery file.
public struct MarkerAppearance: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable {
        case numberedPins, plainDots, numberedDots
        public var name: String {
            switch self {
            case .numberedPins: "Numbered pins"
            case .plainDots: "Plain dots"
            case .numberedDots: "Numbered dots"
            }
        }
        public var guidance: String {
            switch self {
            case .numberedPins: "Numbered pins keep sequence numbers on the photo."
            case .plainDots: "Plain dots hide numbers on the photo. Select a dot to read its number below the photo."
            case .numberedDots: "Numbers stay inside centered circles. Longer numbers need larger circles. At photo edges, badges and numbers can clip. Select a badge to read its full number below the photo."
            }
        }
        public var exportGuidance: String {
            switch self {
            case .numberedPins: "Complete on-photo sequence numbers are included. Selection outlines are not exported."
            case .plainDots: "On-photo sequence numbers are omitted. Selection outlines are not exported."
            case .numberedDots: "Centered badges clip at photo edges; edge numbers may be cut off. Use Numbered pins for complete edge labels. Selection outlines are not exported."
            }
        }
    }
    public enum Color: String, CaseIterable, Sendable {
        case legacy, white, yellow, coral, cyan
        public var name: String {
            switch self {
            case .legacy: "Original"
            case .white: "White"
            case .yellow: "Yellow"
            case .coral: "Coral"
            case .cyan: "Cyan"
            }
        }
        public var fill: CGColor {
            let hex: UInt32 = switch self {
            case .legacy: 0x193A4A
            case .white: 0xFFFFFF
            case .yellow: 0xFFE14A
            case .coral: 0xFF7A6B
            case .cyan: 0x32D5E8
            }
            return CGColor(srgbRed: CGFloat((hex >> 16) & 255)/255,
                           green: CGFloat((hex >> 8) & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1)
        }
    }
    public let style: Style
    public let color: Color
    public init(style: Style, color: Color) { self.style = style; self.color = color }
    public static let defaultAppearance = MarkerAppearance(style: .numberedDots, color: .legacy)
    public static let styleKey = "markerAppearance.style"
    public static let colorKey = "markerAppearance.color"
    public static func resolve(defaults: UserDefaults) -> MarkerAppearance {
        MarkerAppearance(style: (defaults.object(forKey: styleKey) as? String).flatMap(Style.init(rawValue:)) ?? .numberedDots,
                         color: (defaults.object(forKey: colorKey) as? String).flatMap(Color.init(rawValue:)) ?? .legacy)
    }
}
