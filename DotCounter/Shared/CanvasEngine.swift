import SwiftUI
import DotCounterCore
import QuartzCore

/// Only one surface pair can be under preparation across all engines/windows.
/// Each pair uses two independent bitmap contexts; neither job waits for another
/// preparation. Cancellation while waiting is checked at ten-millisecond intervals.
private final class CanvasSurfacePreparation: @unchecked Sendable {
    static let admission = DispatchSemaphore(value: 1)
    private let lock = NSLock()
    private var results: [Result<CGImage?, Error>?] = [nil, nil]
    func store(_ result: Result<CGImage?, Error>, at index: Int) {
        lock.lock(); defer { lock.unlock() }; results[index] = result
    }
    func images() throws -> (CGImage, CGImage)? {
        lock.lock(); defer { lock.unlock() }
        guard let hidden = try results[0]?.get(), let shown = try results[1]?.get() else { return nil }
        return (hidden, shown)
    }
}

@MainActor final class CanvasEngine {
    var workspace: Workspace
    var appearance: MarkerAppearance
    var connections: ConnectionPresentation
    var viewport = ViewportTransform(imageSize: CGSize(width: 1, height: 1), canvasSize: .zero)
    var imageID: UUID?
    var publicationEpoch: UUID?
    var gestureEpoch: UUID?
    var lastFit = -1, lastZoom = 0
    var lastBirdCenter = -1
    var lastSelection: UUID?
    var reviewScale:CGFloat = 5
    var reviewRun:UUID?
    var start: CGPoint?, previous: CGPoint?, movingID: UUID?, preview: CGPoint?
    var dragged = false, navigation = false
    var invalidate: (() -> Void)?
    private struct OverlayKey: Equatable, Sendable {
        let workspace: UUID
        let revision: UInt64
        let size: CGSize
        let backing: CGFloat
        let appearance: MarkerAppearance
        let selection: UUID?
        let previewWidth: Int
        let previewHeight: Int
    }
    /// One current complete shown/hidden surface pair, plus one prepared pair.
    /// The surfaces span the whole photo at the current source scale, so panning
    /// only translates it. Zoom/geometry/appearance/order always use a new key.
    private struct MarkerOverlay: @unchecked Sendable {
        let key: OverlayKey
        let hidden: CGImage
        let shown: CGImage
    }
    private var markerOverlay: MarkerOverlay?
    private var preparedOverlay: MarkerOverlay?
    private var backingScale: CGFloat = 1
    #if DEBUG
    var qaDidDraw: ((Double) -> Void)?
    var qaDisableMarkerCache = false
    var qaSerialSurfacePreparation = false
    #endif
    init(_ workspace: Workspace) {
        self.workspace = workspace
        appearance = workspace.appearance
        connections = workspace.connections
        #if DEBUG
        if NativeQARecorder.shared.enabled, ProcessInfo.processInfo.environment["DOTCOUNTER_QA_CONTINUOUS_NAV"] == "1" {
            NativeQARecorder.shared.navigationDriver = { [weak self] seconds in
                guard let self else { return }
                self.pan(CGSize(width: sin(seconds * 3) * 1.5, height: cos(seconds * 2) * 0.8))
                self.zoom(exp(sin(seconds * 2) * 0.0008), at: CGPoint(x: self.viewport.canvasSize.width / 2, y: self.viewport.canvasSize.height / 2))
            }
        }
        #endif
    }
    func update(size: CGSize, workingRect: CGRect? = nil) {
        workspace.prepareRenumberDrawing = { [weak self] markers, snapshot, control in
            guard let self, markers.count >= 2_000, self.viewport.scale == self.viewport.fitScale else { return }
            guard let photo = self.workspace.candidate?.preview else { return }
            let key = self.overlayKey(snapshot: snapshot)
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.makeOverlay(key: key, markers: markers, photo: photo, control: control)
            }.value
            try control.checkCancellation()
            self.preparedOverlay = result
        }
        let geometryChanged = size != viewport.canvasSize || (workingRect != nil && workingRect != viewport.workingRect)
        if geometryChanged { cancel() }
        if publicationEpoch != workspace.lifecycleEpoch { cancel(); publicationEpoch = workspace.lifecycleEpoch }
        if imageID != workspace.snapshot?.workspaceID {
            imageID = workspace.snapshot?.workspaceID
            markerOverlay = nil; preparedOverlay = nil
            let identity = workspace.candidate?.identity
            viewport = ViewportTransform(imageSize: CGSize(width: identity?.pixelWidth ?? 1, height: identity?.pixelHeight ?? 1), canvasSize: size)
            cancel()
        }
        viewport.resize(to: size, workingRect: workingRect)
        if lastFit != workspace.fitCommand { viewport.fit(); lastFit = workspace.fitCommand }
        if lastZoom != workspace.zoomCommand { viewport.zoom(by: pow(1.4, CGFloat(workspace.zoomCommand - lastZoom)), around: CGPoint(x: size.width/2, y: size.height/2)); lastZoom = workspace.zoomCommand; if workspace.birdReview?.phase == .guided { reviewScale=viewport.scale }; if viewport.zoomFactor > 1.5 { workspace.requestDetail() } }
        if let review=workspace.birdReview {
            if reviewRun != review.key.run {reviewRun=review.key.run;reviewScale=5}
            if lastBirdCenter != workspace.birdCenterCommand {
                lastBirdCenter=workspace.birdCenterCommand
                if review.phase == .guided,let target=workspace.birdCurrent {viewport.focus(x:target.x,y:target.y,sourceScale:reviewScale);workspace.requestDetail()}
            }
        } else {reviewRun=nil}
        if let selected = workspace.selectedID,
           let marker = workspace.markers.first(where: { $0.id == selected }) {
            if selected != lastSelection || geometryChanged { viewport.reveal(x: marker.x, y: marker.y) }
            lastSelection = selected
        } else { lastSelection = nil }
    }
    func draw(_ context: CGContext, size: CGSize) {
        #if DEBUG
        let qaStarted = CACurrentMediaTime()
        defer {
            qaDidDraw?(CACurrentMediaTime() - qaStarted)
            if let snapshot = workspace.snapshot, let identity = workspace.candidate?.identity {
                NativeQARecorder.shared.drewCanvas(revision: snapshot.revision, total: workspace.total, image: [identity.pixelWidth, identity.pixelHeight], started: qaStarted)
            }
        }
        #endif
        context.setFillColor(CGColor(red: 0.859, green: 0.89, blue: 0.898, alpha: 1)); context.fill(CGRect(origin: .zero, size: size))
        guard let candidate = workspace.candidate else { return }
        let rect = viewport.imageRect
        context.saveGState(); context.clip(to: rect.intersection(CGRect(origin: .zero, size: size)))
        let appearance = self.appearance
        let center: (Marker) -> CGPoint = { marker in
            let normalized = marker.id == self.movingID ? self.preview : nil
            return self.viewport.screenPoint(x: Double(normalized?.x ?? CGFloat(marker.x)), y: Double(normalized?.y ?? CGFloat(marker.y)))
        }
        backingScale = max(1, hypot(context.ctm.a, context.ctm.b))
        var overlay: MarkerOverlay?
        #if DEBUG
        let cacheAllowed = !qaDisableMarkerCache
        #else
        let cacheAllowed = true
        #endif
        if cacheAllowed, workspace.total >= 2_000, movingID == nil, viewport.scale == viewport.fitScale, let snapshot = workspace.snapshot {
            let key = overlayKey(snapshot: snapshot)
            if markerOverlay?.key == key { overlay = markerOverlay }
            else if preparedOverlay?.key == key {
                markerOverlay = preparedOverlay; preparedOverlay = nil; overlay = markerOverlay
            } else {
                // Initial/zoom/drag-invalidated drawing remains a complete frame.
                // Renumber prepares this same bounded surface off-main before commit.
                #if DEBUG
                let parallel = !qaSerialSurfacePreparation
                #else
                let parallel = true
                #endif
                markerOverlay = try? Self.makeOverlay(key: key, markers: workspace.markers, photo: candidate.preview, control: .init(), parallel: parallel)
                overlay = markerOverlay
            }
        }
        if let overlay {
            let image = connections.isVisible ? overlay.shown : overlay.hidden
            context.saveGState()
            let drawnSize = CGSize(width: CGFloat(image.width) / overlay.key.backing,
                                   height: CGFloat(image.height) / overlay.key.backing)
            context.translateBy(x: rect.minX, y: rect.minY + drawnSize.height)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(origin: .zero, size: drawnSize))
            context.restoreGState()
        } else {
            context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high; context.draw(candidate.preview, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
            ConnectionRenderer.draw(context: context, markers: workspace.markers, bounds: rect,
                                    presentation: connections, center: center)
            for (index, marker) in workspace.markers.enumerated() {
                MarkerRenderer.draw(context: context, label: index + 1, center: center(marker), bounds: rect,
                                    fontSize: 12, selected: marker.id == workspace.selectedID, appearance: appearance)
            }
        }
        if let review=workspace.birdReview {
            for (i,p) in review.suggestions.enumerated() where workspace.birdShowOthers || (review.phase == .guided && i==review.current) {
                let point=viewport.screenPoint(x:p.x,y:p.y),current=review.phase == .guided && i==review.current
                context.setStrokeColor(review.decisions[i] == .rejected ? Design.rejectedStroke:Design.proposalStroke);context.setLineWidth(current ? 2:1.5)
                context.setLineDash(phase:0,lengths:current ? [4,3]:[])
                let radius:CGFloat=current ? 20:4
                context.strokeEllipse(in:CGRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2));context.setLineDash(phase:0,lengths:[])
                if current || review.decisions[i] == .rejected {context.move(to:CGPoint(x:point.x-7,y:point.y));context.addLine(to:CGPoint(x:point.x+7,y:point.y));context.move(to:CGPoint(x:point.x,y:point.y-7));context.addLine(to:CGPoint(x:point.x,y:point.y+7));context.strokePath()}
            }
            context.setStrokeColor(Design.draftStroke);context.setLineWidth(2)
            for draft in review.drafts {let p=viewport.screenPoint(x:draft.x,y:draft.y);context.move(to:CGPoint(x:p.x-6,y:p.y));context.addLine(to:CGPoint(x:p.x+6,y:p.y));context.move(to:CGPoint(x:p.x,y:p.y-6));context.addLine(to:CGPoint(x:p.x,y:p.y+6));context.strokePath()}
            let epoch=review.epoch,key=review.key
            Task { @MainActor [weak workspace] in if workspace?.birdReview?.key==key,workspace?.birdReview?.epoch==epoch {workspace?.birdTargetReady=epoch} }
        }
        context.restoreGState()
    }
    private func overlayKey(snapshot: RecoverySnapshot) -> OverlayKey {
        OverlayKey(workspace: snapshot.workspaceID, revision: snapshot.revision, size: viewport.imageRect.size,
                   backing: backingScale, appearance: appearance, selection: workspace.selectedID,
                   previewWidth: workspace.candidate?.preview.width ?? 0, previewHeight: workspace.candidate?.preview.height ?? 0)
    }
    private nonisolated static func makeOverlay(key: OverlayKey, markers: [Marker], photo: CGImage,
                                                control: NearestNeighborCancellation, parallel: Bool = true) throws -> MarkerOverlay? {
        try control.checkCancellation()
        let width = ceil(key.size.width * key.backing), height = ceil(key.size.height * key.backing)
        // Each shown/hidden pair is at most 64MiB combined. At most one current
        // pair and one prepared replacement are retained; large zooms draw directly.
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, width * height <= 8_000_000 else { return nil }
        @Sendable func render(_ visible: Bool) throws -> CGImage? {
            try control.checkCancellation()
            guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                bytesPerRow: Int(width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.translateBy(x: 0, y: height); context.scaleBy(x: key.backing, y: -key.backing)
            let bounds = CGRect(origin: .zero, size: key.size)
            context.setFillColor(CGColor(red: 0.859, green: 0.89, blue: 0.898, alpha: 1)); context.fill(bounds)
            context.saveGState(); context.translateBy(x: 0, y: key.size.height); context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .high; context.draw(photo, in: bounds); context.restoreGState()
            try ConnectionRenderer.draw(context: context, markers: markers, bounds: bounds,
                presentation: ConnectionPresentation(isVisible: visible),
                center: { CGPoint(x: $0.x * key.size.width, y: $0.y * key.size.height) },
                checkCancellation: { try control.checkCancellation() })
            for (index, marker) in markers.enumerated() {
                if index & 255 == 0 { try control.checkCancellation() }
                MarkerRenderer.draw(context: context, label: index + 1,
                    center: CGPoint(x: marker.x * key.size.width, y: marker.y * key.size.height),
                    bounds: bounds, selected: marker.id == key.selection, appearance: key.appearance)
            }
            try control.checkCancellation()
            return context.makeImage()
        }
        // Admission is shared by synchronous misses and detached renumber work.
        // Always drain both jobs before returning, including cancellation/error.
        while CanvasSurfacePreparation.admission.wait(timeout: .now() + .milliseconds(10)) == .timedOut {
            try control.checkCancellation()
        }
        defer { CanvasSurfacePreparation.admission.signal() }
        try control.checkCancellation()
        let preparation = CanvasSurfacePreparation()
        if parallel {
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                preparation.store(Result { try render(index == 1) }, at: index)
            }
        } else {
            preparation.store(Result { try render(false) }, at: 0)
            preparation.store(Result { try render(true) }, at: 1)
        }
        try control.checkCancellation()
        guard let images = try preparation.images() else { return nil }
        return MarkerOverlay(key: key, hidden: images.0, shown: images.1)
    }
    #if DEBUG
    nonisolated static func qaPrepareSurfaces(markers: [Marker], photo: CGImage, size: CGSize,
                                             control: NearestNeighborCancellation) throws {
        let key = OverlayKey(workspace: UUID(), revision: 0, size: size, backing: 2,
            appearance: .defaultAppearance, selection: nil, previewWidth: photo.width, previewHeight: photo.height)
        _ = try makeOverlay(key: key, markers: markers, photo: photo, control: control)
    }
    #endif
    func begin(_ point: CGPoint, radius: CGFloat, forcePan: Bool = false) {
        guard !workspace.busy, !workspace.clearing, workspace.candidate != nil else { return }
        cancel(); gestureEpoch = workspace.lifecycleEpoch; start = point; previous = point; navigation = forcePan
        if !forcePan, workspace.mode == .edit,workspace.birdReview==nil { movingID = viewport.nearestMarker(at: point, markers: workspace.markers, radius: radius); if let movingID { workspace.selectedID = movingID } }
    }
    func drag(_ point: CGPoint, threshold: CGFloat) {
        guard let gestureEpoch, workspace.isLive(gestureEpoch), let start, let previous else { return }
        if hypot(point.x - start.x, point.y - start.y) >= threshold { dragged = true }
        guard dragged else { return }
        if let movingID, !navigation {
            _ = movingID; preview = viewport.normalizedPoint(at: point)
        } else { viewport.pan(by: CGPoint(x: point.x - previous.x, y: point.y - previous.y)) }
        self.previous = point; invalidate?()
    }
    func end(_ point: CGPoint, radius: CGFloat) {
        defer { cancel(); invalidate?() }
        guard let gestureEpoch, workspace.isLive(gestureEpoch), start != nil else { return }
        if dragged {
            if let movingID, let location = viewport.normalizedPoint(at: point), !navigation { workspace.move(movingID, to: location) }
        } else if !navigation, let location = viewport.normalizedPoint(at: point) {
            workspace.tap(location, hit: viewport.nearestMarker(at: point, markers: workspace.markers, radius: radius))
        }
    }
    func cancel() { gestureEpoch = nil; start = nil; previous = nil; movingID = nil; preview = nil; dragged = false; navigation = false }
    func zoom(_ factor: CGFloat, at point: CGPoint) { guard !workspace.clearing else { return }; cancel(); viewport.zoom(by: factor, around: point);if workspace.birdReview?.phase == .guided{reviewScale=viewport.scale}; if viewport.zoomFactor > 1.5 { workspace.requestDetail() }; invalidate?() }
    func pan(_ delta: CGSize) { guard !workspace.clearing else { return }; cancel(); viewport.pan(by: CGPoint(x: delta.width, y: delta.height)); invalidate?() }
}
