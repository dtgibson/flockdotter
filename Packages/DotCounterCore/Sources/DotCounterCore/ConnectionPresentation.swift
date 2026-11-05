import Foundation

/// Installation-local display state, independent of count data and marker appearance.
public struct ConnectionPresentation: Equatable, Sendable {
    public let isVisible: Bool

    public init(isVisible: Bool) { self.isVisible = isVisible }

    public static let hidden = ConnectionPresentation(isVisible: false)
    public static let shown = ConnectionPresentation(isVisible: true)
    public static let visibilityKey = "connections.visibility"

    public var storageValue: String { isVisible ? "shown" : "hidden" }
    public var exportGuidance: String { isVisible ? "Connections shown." : "Connections hidden." }

    public static func resolve(defaults: UserDefaults) -> ConnectionPresentation {
        // Do not accept UserDefaults' numeric/Boolean coercion as a supported preference.
        ConnectionPresentation(isVisible: defaults.object(forKey: visibilityKey) as? String == "shown")
    }
}
