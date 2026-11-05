import SwiftUI
import DotCounterCore

struct MarkerAppearanceView: View {
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var textSize
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !textSize.isAccessibilitySize {
                        // The shared evidence renderer draws samples only; no count mutation.
                        Canvas { context, size in
                            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Design.canvas))
                            context.withCGContext { cg in
                                let bounds = CGRect(origin: .zero, size: size)
                                if let photo = workspace.candidate?.preview {
                                    cg.saveGState(); cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
                                    cg.draw(photo, in: bounds); cg.restoreGState()
                                }
                                for (i, x) in [0.2, 0.5, 0.8].enumerated() {
                                    let appearance = workspace.candidate == nil
                                        ? MarkerAppearance(style: MarkerAppearance.Style.allCases[i], color: workspace.appearance.color)
                                        : workspace.appearance
                                    MarkerRenderer.draw(context: cg, label: [1, 18, 1234][i],
                                                        center: CGPoint(x: size.width*x, y: size.height/2),
                                                        bounds: bounds, appearance: appearance)
                                }
                            }
                        }.frame(height: 100).accessibilityHidden(true)
                    }
                    Text("Style").font(Design.font(15, bold: true))
                    VStack(spacing: 0) {
                        ForEach(MarkerAppearance.Style.allCases, id: \.self) { style in
                            choice(style.name, selected: workspace.appearance.style == style) { workspace.setMarkerStyle(style) }
                                .accessibilityIdentifier("markerStyle-\(style.rawValue)")
                        }
                    }
                    Text("Color").font(Design.font(15, bold: true))
                    VStack(spacing: 0) {
                        ForEach(MarkerAppearance.Color.allCases, id: \.self) { color in
                            choice(color.name, subtitle: color == .legacy ? "Default · navy & white" : nil,
                                   color: color, selected: workspace.appearance.color == color) { workspace.setMarkerColor(color) }
                                .accessibilityIdentifier("markerColor-\(color.rawValue)")
                        }
                    }
                    Text(workspace.appearance.style.guidance).font(Design.font(13)).foregroundStyle(Design.secondary)
                    Button("Reset to defaults") { workspace.resetMarkerAppearance() }
                        .disabled(workspace.appearance == .defaultAppearance).frame(minHeight: 44)
                        .accessibilityIdentifier("resetMarkerAppearance")
                    Text("Restores Numbered dots and Original. Choices stay on this app installation, including after you clear a workspace.")
                        .font(Design.font(13)).foregroundStyle(Design.secondary)
                }.padding(24)
            }.background(Design.surface).navigationTitle("Marker appearance")
                .toolbarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) { Text("Marker appearance").font(Design.font(20, bold: true)).lineLimit(2) }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
                }
        }.font(Design.font()).foregroundStyle(Design.ink).tint(Design.accent)
            .buttonStyle(InstrumentButtonStyle()).preferredColorScheme(.light)
            .instrumentSheet(width: 430, minimumHeight: 400)
            .presentationDetents([.large])
    }
    private func choice(_ name: String, subtitle: String? = nil, color: MarkerAppearance.Color? = nil,
                        selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let color {
                    Circle().fill(Color(cgColor: color.fill)).frame(width: 20, height: 20)
                        .overlay(Circle().stroke(Design.navy, lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                    if let subtitle { Text(subtitle).font(Design.font(12)).foregroundStyle(Design.secondary) }
                }
                Spacer(minLength: 8)
                Image(systemName: "checkmark").opacity(selected ? 1 : 0).accessibilityHidden(true)
            }.frame(maxWidth: .infinity, minHeight: 52, alignment: .leading).contentShape(Rectangle())
        }.accessibilityLabel(name).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
