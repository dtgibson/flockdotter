import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@main struct DotCounterApp: App {
    @State private var workspace = Workspace()
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
    init() {
        #if DEBUG
        _ = NativeQARecorder.shared
        #endif
        Design.registerFonts()
    }
    var body: some Scene {
        #if os(macOS)
        Window("Flock Dotter", id: "workspace") {
            WorkspaceView(workspace: workspace).frame(minWidth: 480, minHeight: 540)
                .background(WindowCloseHook(workspace: workspace))
                .onAppear { appDelegate.workspace = workspace }
                .onChange(of:scenePhase){_,phase in if phase == .background{workspace.invalidateRenumber(); workspace.invalidateBirdDetection()}}
        }.defaultSize(width: 1120, height: 800)
            .commands { CommandGroup(replacing: .newItem) {
                Button("Open Photo…") { workspace.openPhotoFiles() }.keyboardShortcut("o").disabled(!workspace.canOpen)
                Button("Reopen Count…") { workspace.openCountFile() }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!workspace.canOpen)
            } }
        #else
        WindowGroup { WorkspaceView(workspace: workspace) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background {
                    workspace.invalidateRenumber(); workspace.invalidateBirdDetection()
                    let identifier = UIApplication.shared.beginBackgroundTask(withName: "Save current count")
                    Task { await workspace.flush(); if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier) } }
                }
            }
        #endif
    }
}
#if os(macOS)
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var workspace: Workspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        workspace.invalidateRenumber(); workspace.invalidateBirdDetection()
        Task {
            await workspace.flush()
            if workspace.recoveryStale {
                let alert = NSAlert(); alert.messageText = "Recovery isn’t up to date"
                alert.informativeText = "Your count is still here. Cancel quitting to retry or export JSON."
                alert.addButton(withTitle: "Cancel Quit"); alert.addButton(withTitle: "Quit Anyway")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
            } else { sender.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }
}
#endif
