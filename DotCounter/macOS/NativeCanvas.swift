import SwiftUI
import DotCounterCore
import AppKit

struct NativeCanvas: NSViewRepresentable {
    let workspace: Workspace
    let appearance: MarkerAppearance
    let connections: ConnectionPresentation
    func makeNSView(context: Context) -> PointerCanvas { PointerCanvas(workspace) }
    func updateNSView(_ view: PointerCanvas, context: Context) { view.engine.workspace = workspace; view.engine.appearance = appearance; view.engine.connections = connections; view.engine.update(size: view.bounds.size); view.needsDisplay = true; view.setAccessibilityValue(workspace.markedBirds + (workspace.selectedLabel.map { ", Marker \($0) selected" } ?? "")); view.requestReviewKeyboardFocus() }
}
@MainActor final class PointerCanvas: NSView {
    let engine: CanvasEngine
    private var space = false
    private var decisionKeys:Set<UInt16> = []
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var reviewKeyboardAvailable:Bool {
        guard let window,window.isKeyWindow,window.attachedSheet == nil,NSApp.modalWindow == nil,!engine.workspace.exportShown else{return false}
        return engine.workspace.birdReview?.phase == .guided
    }
    func requestReviewKeyboardFocus() {DispatchQueue.main.async { [weak self] in
        guard let self,let window=self.window else{return}
        guard self.engine.workspace.birdReview?.phase == .guided else {if window.firstResponder === self {window.makeFirstResponder(nil)};return}
        guard self.reviewKeyboardAvailable else{return}
        let responder=window.firstResponder
        // Preserve another control/editor's focus; claim only the idle window/content route.
        if responder == nil || responder === window || responder === window.contentView {window.makeFirstResponder(self)}
    }}
    init(_ workspace: Workspace) {
        engine = CanvasEngine(workspace); super.init(frame: .zero)
        engine.invalidate = { [weak self] in self?.needsDisplay = true }
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Photo counting canvas")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() { super.layout(); engine.update(size: bounds.size) }
    override func draw(_ dirtyRect: NSRect) {
        if let context = NSGraphicsContext.current?.cgContext { engine.draw(context, size: bounds.size)
            if window?.firstResponder === self { context.setStrokeColor(CGColor(red: 0.098, green: 0.227, blue: 0.29, alpha: 1)); context.setLineWidth(2); context.stroke(bounds.insetBy(dx: 1, dy: 1)) }
        }
    }
    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); engine.begin(point(event), radius: 12, forcePan: space); needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        engine.drag(point(event), threshold: 4)
        #if DEBUG
        if engine.dragged { NativeQARecorder.shared.navigation() }
        #endif
    }
    override func mouseUp(with event: NSEvent) {
        #if DEBUG
        NativeQARecorder.shared.begin("Canvas mouse release", timestamp: event.timestamp)
        #endif
        engine.end(point(event), radius: 12); needsDisplay = true
    }
    override func otherMouseDown(with event: NSEvent) { if event.buttonNumber == 2 { window?.makeFirstResponder(self); engine.begin(point(event), radius: 12, forcePan: true) } }
    override func otherMouseDragged(with event: NSEvent) { if event.buttonNumber == 2 { engine.drag(point(event), threshold: 0) } }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { engine.end(point(event), radius: 12) } }
    override func scrollWheel(with event: NSEvent) {
        #if DEBUG
        NativeQARecorder.shared.navigation()
        #endif
        if event.modifierFlags.contains(.option) { engine.zoom(exp(-event.scrollingDeltaY * 0.015), at: point(event)) } else { engine.pan(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY)) } }
    override func magnify(with event: NSEvent) {
        #if DEBUG
        NativeQARecorder.shared.navigation()
        #endif
        engine.zoom(max(0.1, 1 + event.magnification), at: point(event)) }
    override func keyDown(with event: NSEvent) {
        if ["f","j"].contains(event.charactersIgnoringModifiers?.lowercased() ?? ""),let r=engine.workspace.birdReview,r.phase == .guided,let target=engine.workspace.birdCurrent {
            guard window?.firstResponder === self,reviewKeyboardAvailable,event.modifierFlags.intersection([.command,.control,.option,.shift]).isEmpty,!event.isARepeat,decisionKeys.insert(event.keyCode).inserted else{return}
            engine.workspace.decideBird(event.charactersIgnoringModifiers=="f" ? .rejected:.accepted,target:target.id,epoch:r.epoch);return
        }
        switch event.keyCode {
        case 49: space = true; engine.cancel()
        case 51, 117: engine.workspace.remove()
        case 53: engine.cancel(); engine.workspace.deselect(); needsDisplay = true
        default: super.keyDown(with: event)
        }
    }
    override func keyUp(with event: NSEvent) { decisionKeys.remove(event.keyCode);if event.keyCode == 49 { space = false } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool { decisionKeys.removeAll();space = false; engine.cancel(); needsDisplay = true; return super.resignFirstResponder() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { engine.cancel() };requestReviewKeyboardFocus() }
}
