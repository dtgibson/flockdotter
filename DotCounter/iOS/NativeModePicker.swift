import SwiftUI
import UIKit
struct NativeModePicker: UIViewRepresentable {
    let workspace: Workspace
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    func makeCoordinator() -> Coordinator { Coordinator(workspace) }
    func makeUIView(context: Context) -> ModeSegmentedControl {
        let view = ModeSegmentedControl(items: ["Count", "Edit"])
        view.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        view.selectedSegmentTintColor = .white
        view.backgroundColor = UIColor(red: 237/255, green: 243/255, blue: 244/255, alpha: 1)
        let ink = UIColor(red: 20/255, green: 42/255, blue: 54/255, alpha: 1)
        view.setTitleTextAttributes([.foregroundColor: ink], for: .normal)
        view.setTitleTextAttributes([.foregroundColor: ink], for: .selected)
        view.layer.borderColor = UIColor(red: 159/255, green: 177/255, blue: 184/255, alpha: 1).cgColor
        view.layer.borderWidth = 0; view.layer.cornerRadius = 18
        view.overrideUserInterfaceStyle = .light
        view.accessibilityLabel = "Count or Edit mode"
        view.updateFont()
        return view
    }
    func updateUIView(_ view: ModeSegmentedControl, context: Context) {
        _ = dynamicTypeSize
        view.updateFont()
        view.selectedSegmentIndex = workspace.mode == .count ? 0 : 1
        view.isEnabled = workspace.candidate != nil && !workspace.busy && !workspace.clearing && !workspace.exportShown
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ModeSegmentedControl, context: Context) -> CGSize? { uiView.intrinsicContentSize }
    @MainActor final class Coordinator: NSObject {
        let workspace: Workspace
        init(_ workspace: Workspace) { self.workspace = workspace }
        @objc func changed(_ sender: UISegmentedControl) { workspace.changeMode(sender.selectedSegmentIndex == 0 ? .count : .edit) }
    }
}

/// UIKit owns the content-size traits, including changes after this view is made.
@MainActor final class ModeSegmentedControl: UISegmentedControl {
    private(set) var titleFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
    func updateFont() {
        let base = UIFont(name: "IBMPlexSans-SemiBold", size: 14) ?? UIFont.systemFont(ofSize: 14, weight: .semibold)
        titleFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traitCollection)
        for state: UIControl.State in [.normal, .selected] {
            var attributes = titleTextAttributes(for: state) ?? [:]
            attributes[.font] = titleFont
            setTitleTextAttributes(attributes, for: state)
        }
        invalidateIntrinsicContentSize()
    }
    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory { updateFont() }
    }
    override var intrinsicContentSize: CGSize {
        let widest = ["Count", "Edit"].map { ($0 as NSString).size(withAttributes: [.font: titleFont]).width }.max() ?? 0
        return CGSize(width: max(140, ceil(widest * 2 + 40)), height: max(44, ceil(titleFont.lineHeight + 20)))
    }
}
