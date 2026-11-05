import SwiftUI
import AppKit

/// Defer the single workspace window's normal close until its pending recovery
/// commit resolves. Forward SwiftUI's other native window delegate messages.
struct WindowCloseHook: NSViewRepresentable {
    let workspace: Workspace
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.moved = { [weak coordinator = context.coordinator] window in coordinator?.attach(window) }
        return view
    }
    func updateNSView(_ view: HookView, context: Context) {}
    final class HookView: NSView {
        var moved: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); moved?(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let workspace: Workspace
        nonisolated(unsafe) weak var previous: (any NSWindowDelegate)?
        weak var window: NSWindow?
        var allowed = false
        var flushing = false
        init(workspace: Workspace) { self.workspace = workspace }
        func attach(_ window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            self.window = window; previous = window.delegate; window.delegate = self
        }
        // Cocoa asks these Objective-C introspection methods outside actor
        // checking. The weak reference is installed only on the UI thread.
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || previous?.responds(to: selector) == true }
        override func forwardingTarget(for selector: Selector!) -> Any? { previous?.responds(to: selector) == true ? previous : super.forwardingTarget(for: selector) }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            workspace.invalidateRenumber(); workspace.invalidateBirdDetection()
            if allowed { allowed = false; return previous?.windowShouldClose?(sender) ?? true }
            guard !flushing else { return false }
            flushing = true
            Task {
                await workspace.flush()
                flushing = false
                if workspace.recoveryStale {
                    let alert = NSAlert(); alert.messageText = "Recovery isn’t up to date"
                    alert.informativeText = "Your count is still here. Keep the window open to retry or export JSON."
                    alert.addButton(withTitle: "Keep Open"); alert.addButton(withTitle: "Close Anyway")
                    guard alert.runModal() == .alertSecondButtonReturn else { return }
                }
                allowed = true; sender.performClose(nil)
            }
            return false
        }
    }
}
