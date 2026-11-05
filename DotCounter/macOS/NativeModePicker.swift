import SwiftUI
import AppKit
struct NativeModePicker: NSViewRepresentable {
    let workspace: Workspace
    func makeCoordinator() -> Coordinator { Coordinator(workspace) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let view = NSSegmentedControl(labels: ["Count", "Edit"], trackingMode: .selectOne, target: context.coordinator, action: #selector(Coordinator.changed(_:)))
        view.segmentStyle = .rounded; view.selectedSegmentBezelColor = .white
        view.font = NSFont(name: "IBMPlexSans-SemiBold", size: 14)
        view.appearance = NSAppearance(named: .aqua)
        view.setWidth(78, forSegment: 0); view.setWidth(78, forSegment: 1)
        view.setAccessibilityLabel("Count or Edit mode")
        return view
    }
    func updateNSView(_ view: NSSegmentedControl, context: Context) { view.selectedSegment = workspace.mode == .count ? 0 : 1; view.isEnabled = workspace.candidate != nil && !workspace.busy && !workspace.clearing && !workspace.exportShown }
    @MainActor final class Coordinator: NSObject {
        let workspace: Workspace
        init(_ workspace: Workspace) { self.workspace = workspace }
        @objc func changed(_ sender: NSSegmentedControl) { workspace.changeMode(sender.selectedSegment == 0 ? .count : .edit) }
    }
}
