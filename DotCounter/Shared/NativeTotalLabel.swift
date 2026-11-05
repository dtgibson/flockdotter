import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The visible numeric total is a native text label. Its glyph draw can be
/// observed in opt-in Debug evidence without adding an invisible stand-in.
struct NativeTotalLabel: View {
    let value: Int
    let revision: UInt64
    @ScaledMetric(relativeTo: .largeTitle) private var pointSize: CGFloat = 42
    init(value: Int, revision: UInt64, compact: Bool) {
        self.value = value; self.revision = revision
        _pointSize = ScaledMetric(wrappedValue: 42, relativeTo: .largeTitle)
    }
    var body: some View {
        NativeTotalAdapter(value: value, revision: revision, pointSize: pointSize)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.firstTextBaseline) { dimensions in dimensions.height * 0.80 }
            .accessibilityHidden(true)
    }
}
#if os(iOS)
private struct NativeTotalAdapter: UIViewRepresentable {
    let value: Int; let revision: UInt64; let pointSize: CGFloat
    func makeUIView(context: Context) -> NativeTotalText {
        let label = NativeTotalText()
        label.adjustsFontSizeToFitWidth = true; label.minimumScaleFactor = 0.5
        label.numberOfLines = 1; label.lineBreakMode = .byClipping
        label.isAccessibilityElement = false
        return label
    }
    func updateUIView(_ label: NativeTotalText, context: Context) {
        label.value = value; label.revision = revision
        label.font = UIFont(name: "IBMPlexMono-SemiBold", size: pointSize) ?? .monospacedSystemFont(ofSize: pointSize, weight: .semibold)
        label.attributedText = NSAttributedString(string: value.formatted(), attributes: [.font: label.font!, .kern: -1, .foregroundColor: UIColor(red: 20/255, green: 42/255, blue: 54/255, alpha: 1)])
        label.invalidateIntrinsicContentSize(); label.setNeedsDisplay()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeTotalText, context: Context) -> CGSize? {
        let ideal = uiView.intrinsicContentSize
        return CGSize(width: min(ideal.width, proposal.width ?? ideal.width), height: ideal.height)
    }
}
@MainActor final class NativeTotalText: UILabel {
    var value = 0; var revision: UInt64 = 0
    override func didMoveToWindow() {
        super.didMoveToWindow()
        #if DEBUG
        NativeQARecorder.shared.attach(self)
        #endif
    }
    override func drawText(in rect: CGRect) {
        super.drawText(in: rect)
        #if DEBUG
        NativeQARecorder.shared.drewTotalGlyphs(revision: revision, total: value)
        #endif
    }
}
#else
private struct NativeTotalAdapter: NSViewRepresentable {
    let value: Int; let revision: UInt64; let pointSize: CGFloat
    func makeNSView(context: Context) -> NativeTotalText {
        let label = NativeTotalText()
        label.isEditable = false; label.isSelectable = false; label.isBezeled = false
        label.isBordered = false; label.drawsBackground = false; label.focusRingType = .none
        label.maximumNumberOfLines = 1; label.lineBreakMode = .byClipping
        label.setAccessibilityElement(false)
        return label
    }
    func updateNSView(_ label: NativeTotalText, context: Context) {
        label.value = value; label.revision = revision
        let font = NSFont(name: "IBMPlexMono-SemiBold", size: pointSize) ?? .monospacedSystemFont(ofSize: pointSize, weight: .semibold)
        label.attributedStringValue = NSAttributedString(string: value.formatted(), attributes: [.font: font, .kern: -1, .foregroundColor: NSColor(red: 20/255, green: 42/255, blue: 54/255, alpha: 1)])
        label.invalidateIntrinsicContentSize(); label.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NativeTotalText, context: Context) -> CGSize? { nsView.intrinsicContentSize }
}
@MainActor final class NativeTotalText: NSTextField {
    var value = 0; var revision: UInt64 = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        #if DEBUG
        NativeQARecorder.shared.attach(self)
        #endif
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        #if DEBUG
        NativeQARecorder.shared.drewTotalGlyphs(revision: revision, total: value)
        #endif
    }
}
#endif
