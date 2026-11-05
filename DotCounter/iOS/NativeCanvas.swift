import SwiftUI
import DotCounterCore
import UIKit

struct NativeCanvas: UIViewRepresentable {
    let workspace: Workspace
    let appearance: MarkerAppearance
    let connections: ConnectionPresentation
    var retainedEngine: CanvasEngine? = nil
    var workingInsets: EdgeInsets = .init()
    func makeUIView(context: Context) -> TouchCanvas { TouchCanvas(workspace, engine: retainedEngine) }
    func updateUIView(_ view: TouchCanvas, context: Context) { view.workingInsets = UIEdgeInsets(top: workingInsets.top, left: workingInsets.leading, bottom: workingInsets.bottom, right: workingInsets.trailing); view.engine.workspace = workspace; view.engine.appearance = appearance; view.engine.connections = connections; view.updateViewport(); view.setNeedsDisplay(); view.accessibilityValue = workspace.markedBirds + (workspace.selectedLabel.map { ", Marker \($0) selected" } ?? ""); view.requestReviewKeyboardFocus() }
}
@MainActor final class TouchCanvas: UIView, UIGestureRecognizerDelegate {
    let engine: CanvasEngine
    var workingInsets: UIEdgeInsets = .zero
    func updateViewport() {
        engine.update(size: bounds.size, workingRect: bounds.inset(by: workingInsets))
    }
    private var pinching = false
    private var radius: CGFloat = 22
    private var decisionKeys:Set<String> = []
    override var canBecomeFirstResponder:Bool{true}
    var reviewKeyboardAvailable:Bool {
        guard let window,window.isKeyWindow,window.rootViewController?.presentedViewController == nil,!engine.workspace.exportShown else{return false}
        return engine.workspace.birdReview?.phase == .guided
    }
    func requestReviewKeyboardFocus() {DispatchQueue.main.async { [weak self] in self?.updateReviewKeyboardFocus() }}
    func updateReviewKeyboardFocus() {
        guard engine.workspace.birdReview?.phase == .guided else {if isFirstResponder{resignFirstResponder()};return}
        guard reviewKeyboardAvailable,!isFirstResponder,let window else{return}
        func hasResponder(_ view:UIView)->Bool {view.isFirstResponder || view.subviews.contains(where:hasResponder)}
        // A text field, form control or other view keeps its existing input focus.
        guard !hasResponder(window) else{return}
        becomeFirstResponder()
    }
    override func didMoveToWindow() {super.didMoveToWindow();requestReviewKeyboardFocus()}
    override func resignFirstResponder()->Bool {decisionKeys.removeAll();return super.resignFirstResponder()}
    override func pressesBegan(_ presses:Set<UIPress>,with event:UIPressesEvent?) {
        if let key=presses.first?.key,["f","j"].contains(key.charactersIgnoringModifiers),let r=engine.workspace.birdReview,r.phase == .guided,let target=engine.workspace.birdCurrent {
            guard isFirstResponder,reviewKeyboardAvailable,key.modifierFlags.isEmpty,decisionKeys.insert(key.charactersIgnoringModifiers).inserted else{return}
            engine.workspace.decideBird(key.charactersIgnoringModifiers=="f" ? .rejected:.accepted,target:target.id,epoch:r.epoch);return
        };super.pressesBegan(presses,with:event)
    }
    override func pressesEnded(_ presses:Set<UIPress>,with event:UIPressesEvent?) {for press in presses{if let key=press.key{decisionKeys.remove(key.charactersIgnoringModifiers)}};super.pressesEnded(presses,with:event)}
    override func pressesCancelled(_ presses:Set<UIPress>,with event:UIPressesEvent?) {decisionKeys.removeAll();super.pressesCancelled(presses,with:event)}
    init(_ workspace: Workspace, engine retained: CanvasEngine? = nil) {
        engine = retained ?? CanvasEngine(workspace); super.init(frame: .zero)
        isMultipleTouchEnabled = true; isOpaque = true; contentMode = .redraw
        engine.invalidate = { [weak self] in self?.setNeedsDisplay() }
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:))); pinch.cancelsTouchesInView = true; addGestureRecognizer(pinch)
        isAccessibilityElement = true; accessibilityLabel = "Photo counting canvas"; accessibilityHint = "Tap each bird in Count mode. Drag to pan. Pinch to zoom."
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Remove selected marker", actionHandler: { [weak self] _ in self?.engine.workspace.remove(); return true }), UIAccessibilityCustomAction(name: "Deselect marker", actionHandler: { [weak self] _ in self?.engine.workspace.deselect(); return true })]
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() { super.layoutSubviews(); updateViewport() }
    override func draw(_ rect: CGRect) { if let context = UIGraphicsGetCurrentContext() { engine.draw(context, size: bounds.size) } }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if engine.workspace.birdReview != nil {becomeFirstResponder()}
        guard event?.buttonMask.contains(.secondary) != true, event?.allTouches?.count == 1, !pinching, let touch = touches.first else { engine.cancel(); return }
        radius = touch.type == .indirectPointer ? 12 : 22
        engine.begin(touch.location(in: self), radius: radius)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { guard !pinching, event?.allTouches?.count == 1, let touch = touches.first else { engine.cancel(); return }; engine.drag(touch.location(in: self), threshold: radius == 12 ? 4 : 8)
        #if DEBUG
        if engine.dragged { NativeQARecorder.shared.navigation() }
        #endif
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !pinching, let touch = touches.first {
            #if DEBUG
            NativeQARecorder.shared.begin("Canvas touch release", timestamp: touch.timestamp)
            #endif
            engine.end(touch.location(in: self), radius: radius)
        }
        setNeedsDisplay()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { engine.cancel(); setNeedsDisplay() }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began {
            pinching = true; engine.cancel()
            #if DEBUG
            NativeQARecorder.shared.navigation()
            #endif
        }
        if gesture.state == .changed { engine.zoom(gesture.scale, at: gesture.location(in: self)); gesture.scale = 1 }
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { pinching = false; engine.cancel() }
    }
}
