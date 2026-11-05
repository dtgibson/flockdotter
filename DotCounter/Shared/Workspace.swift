import SwiftUI
import Observation
import DotCounterCore
import UniformTypeIdentifiers
import os

@MainActor @Observable final class Workspace {
    enum Mode: String, CaseIterable { case count = "Count", edit = "Edit" }
    struct Request: Equatable { let epoch: UUID; let id = UUID() }
    struct ClearTarget {
        let workspace: UUID; let source: UUID; let revision: UInt64; let epoch: UUID
        let filename: String; let total: Int
    }
    private(set) var lifecycleEpoch: UUID
    private(set) var clearing = false
    var clearTarget: ClearTarget?
    var clearFailed = false
    var clearCleanupWarning: String?
    var filesRequest: Request?
    var jsonRequest: Request?
    private var clearTask: Task<Void, Never>?
    private var saveJob: UUID?
    var mode: Mode = .count
    var history = MarkerHistory(markers: [])
    var selectedID: UUID?
    var candidate: ImageCandidate?
    var snapshot: RecoverySnapshot?
    var busy = false
    var committing = false
    var recovering = false
    private var detailRequested: UUID?
    private var started = false
    var error: String?
    var recoveryMessage = ""
    var recoveryStale = false
    var pending: (ImageCandidate, CountDocument)?
    var showReplacement = false
    var pairing: CountDocument?
    var showPairing = false
    var exportShown = false
    var exportTab = 0
    private(set) var exportCapture: ExportCapture?
    private(set) var appearance: MarkerAppearance
    private(set) var connections: ConnectionPresentation
    private(set) var renumberPending = false
    private(set) var renumberProgress = false
    var renumberFailure = false
    private var renumberEligible: UUID?
    private var renumberActive: NearestRequest?
    private var renumberNewest: NearestRequest?
    private var renumberTask: Task<Void, Never>?
    private var renumberTimer: Task<Void, Never>?
    var prepareRenumberDrawing: (([Marker], RecoverySnapshot, NearestNeighborCancellation) async throws -> Void)?

    private struct NearestRequest: Sendable {
        let id = UUID()
        let epoch: UUID
        let snapshot: RecoverySnapshot
        let history: MarkerHistory
        let control = NearestNeighborCancellation()
    }
    var markedBirds: String { "\(total) \(total == 1 ? "bird" : "birds") marked" }
    var markedBirdsNoun: String { total == 1 ? "bird marked" : "birds marked" }
    private let appearanceDefaults: UserDefaults
    var zoomCommand = 0
    var fitCommand = 0
    var openFiles = false
    var openJSON = false
    var birdActivity: BirdActivity = .idle
    var birdReview: BirdReview?
    var birdMessage = ""
    var birdOwner = false
    var birdGeneration = UUID()
    var birdKey: BirdDetectionKey?
    var birdControl: BirdScanControl?
    var birdTask: Task<Void, Never>?
    var birdDeadline: Task<Void, Never>?
    var birdTargetReady: UInt64?
    var birdShowOthers = false
    var birdDraftMode = false
    var birdMovingDraft: UUID?
    var birdCenterCommand = 0
    var birdMeasurement: BirdScanMeasurement?
    private let store: RecoveryStore
    #if DEBUG
    var qaSuspend: ((String) async throws -> Void)?
    var qaBirdScan: ((BirdDetectionKey, @escaping @MainActor (Int, Int) async -> Void) async throws -> [BirdSuggestion])?
    var qaBirdDeadlineWait: (() async -> Void)?
    var qaSaveJob: UUID? { saveJob }
    var qaDetailTask: Task<Void, Never>?
    func qaBoundary(_ point: String) async throws { try await qaSuspend?(point) }
    /// App-hosted regression tests use their own recovery store, never user work.
    init(qaDirectory: URL, defaults: UserDefaults? = nil, fault: (@Sendable (RecoveryFaultPoint) throws -> Void)? = nil) {
        let epoch = UUID(); lifecycleEpoch = epoch
        // Existing hosted tests also receive an isolated domain by default.
        appearanceDefaults = defaults ?? UserDefaults(suiteName: "DotCounterTests-\(UUID().uuidString)")!
        appearance = MarkerAppearance.resolve(defaults: appearanceDefaults)
        connections = ConnectionPresentation.resolve(defaults: appearanceDefaults)
        store = RecoveryStore(directory: qaDirectory, epoch: epoch, fault: fault)
    }
    #endif
    init(defaults: UserDefaults = .standard) {
        let epoch = UUID(); lifecycleEpoch = epoch
        #if DEBUG
        if let session = ProcessInfo.processInfo.environment["DOTCOUNTER_QA_SESSION"], UUID(uuidString: session) != nil {
            appearanceDefaults = UserDefaults(suiteName: "DotCounterUITests-\(session)")!
        } else { appearanceDefaults = defaults }
        #else
        appearanceDefaults = defaults
        #endif
        appearance = MarkerAppearance.resolve(defaults: appearanceDefaults)
        connections = ConnectionPresentation.resolve(defaults: appearanceDefaults)
        #if DEBUG
        if let session = ProcessInfo.processInfo.environment["DOTCOUNTER_QA_SESSION"], UUID(uuidString: session) != nil {
            let heldFailure = ProcessInfo.processInfo.environment["DOTCOUNTER_QA_CLEAR"] == "held-uncertain"
            store = RecoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("DotCounterUITests", isDirectory: true).appendingPathComponent(session, isDirectory: true), epoch: epoch, fault: { point in
                if heldFailure, point == .afterClearRemoval {
                    // Isolated native UI proof of real clearing and retained selection.
                    Thread.sleep(forTimeInterval: 12)
                    throw RecoveryError.injected(point)
                }
            })
        } else { store = RecoveryStore(epoch: epoch) }
        #else
        store = RecoveryStore(epoch: epoch)
        #endif
    }
    private var operation = UUID()
    private var saveTask: Task<Void, Never>?
    private let signposter = OSSignposter(subsystem: "app.dotcounter", category: "Workspace")
    var markers: [Marker] { history.markers }
    var document: CountDocument? { candidate.map { CountDocument(image: $0.identity, markers: markers) } }
    var dirty: Bool { guard let document, let snapshot else { return false }; return document.contentDigest != snapshot.baselineDigest }
    var total: Int { markers.count }
    var selectedLabel: Int? { markers.firstIndex(where: { $0.id == selectedID }).map { $0 + 1 } }
    var stem: String { ((candidate?.identity.originalFilename ?? "Photo") as NSString).deletingPathExtension }

    var canClear: Bool { candidate != nil && snapshot != nil && !clearing && !committing }
    var canOpen: Bool { !busy && !clearing && !committing && !exportShown }
    func isLive(_ epoch: UUID) -> Bool { epoch == lifecycleEpoch && !clearing }
    func newRequest() -> Request? {
        guard canOpen else { return nil }; invalidateRenumber()
        return Request(epoch: lifecycleEpoch)
    }
    func openPhotoFiles(pairingOriginal: Bool = false) {
        guard let request = newRequest() else { return }
        if !pairingOriginal { pairing = nil }
        filesRequest = request; openFiles = true
    }
    func openCountFile() {
        guard let request = newRequest() else { return }
        jsonRequest = request; openJSON = true
    }
    func showExport(tab: Int = 0) {
        guard let candidate, let snapshot, let document, !exportShown, !busy, !clearing, !committing else { return }
        invalidateRenumber()
        exportCapture = ExportCapture(document: document, source: candidate.sourceURL,
                                      workspaceID: snapshot.workspaceID, initialTab: tab,
                                      sourceToken: snapshot.sourceToken, requestEpoch: lifecycleEpoch,
                                      appearance: appearance, connections: connections)
        exportTab = tab; exportShown = true
    }
    func retireExport() { exportCapture = nil }
    func setConnectionsVisible(_ visible: Bool) {
        guard visible != connections.isVisible else { return }
        connections = ConnectionPresentation(isVisible: visible)
        appearanceDefaults.set(connections.storageValue, forKey: ConnectionPresentation.visibilityKey)
    }
    func setMarkerStyle(_ style: MarkerAppearance.Style) {
        guard style != appearance.style else { return }
        appearance = MarkerAppearance(style: style, color: appearance.color)
        appearanceDefaults.set(style.rawValue, forKey: MarkerAppearance.styleKey)
    }
    func setMarkerColor(_ color: MarkerAppearance.Color) {
        guard color != appearance.color else { return }
        appearance = MarkerAppearance(style: appearance.style, color: color)
        appearanceDefaults.set(color.rawValue, forKey: MarkerAppearance.colorKey)
    }
    func resetMarkerAppearance() {
        guard appearance != .defaultAppearance else { return }
        appearance = .defaultAppearance
        appearanceDefaults.set(appearance.style.rawValue, forKey: MarkerAppearance.styleKey)
        appearanceDefaults.set(appearance.color.rawValue, forKey: MarkerAppearance.colorKey)
    }
    func requestClear() {
        guard canClear, let snapshot, let candidate else { return }
        invalidateRenumber()
        clearTarget = ClearTarget(workspace: snapshot.workspaceID, source: snapshot.sourceToken,
                                  revision: snapshot.revision, epoch: lifecycleEpoch,
                                  filename: candidate.identity.originalFilename, total: total)
    }
    func confirmClear(_ target: ClearTarget) async {
        guard canClear, let snapshot else { return }
        guard target.workspace == snapshot.workspaceID, target.source == snapshot.sourceToken,
              target.revision == snapshot.revision, target.epoch == lifecycleEpoch else { requestClear(); return }
        invalidateRenumber()
        clearing = true; clearTarget = nil; clearFailed = false; clearCleanupWarning = nil
        let previousEpoch = lifecycleEpoch, nextEpoch = UUID()
        lifecycleEpoch = nextEpoch; operation = UUID(); detailRequested = nil
        invalidateBirdDetection(); birdMeasurement = nil; birdMovingDraft = nil
        cancelReplacement(); showPairing = false; openFiles = false; openJSON = false
        filesRequest = nil; jsonRequest = nil; exportShown = false; exportCapture = nil; error = nil
        let oldSave = saveTask
        saveTask = nil; saveJob = nil
        busy = false; recovering = false
        clearTask = Task {
            await oldSave?.value
            do {
                let result = try await store.clear(expectedWorkspaceID: target.workspace, sourceToken: target.source,
                                                   previousEpoch: previousEpoch, newEpoch: nextEpoch)
                switch result {
                case .durableEmpty(let warning):
                    candidate = nil; self.snapshot = nil; detailRequested = nil
                    history = MarkerHistory(markers: []); selectedID = nil; mode = .count
                    zoomCommand = 0; fitCommand += 1
                    recoveryStale = false; recoveryMessage = "No photo open"
                    clearCleanupWarning = warning
                case .failed, .durabilityUncertain:
                    clearFailed = true; recoveryStale = true; recoveryMessage = "Recovery needs attention"
                }
            } catch {
                clearFailed = true; recoveryStale = true; recoveryMessage = "Recovery needs attention"
            }
            clearing = false; clearTask = nil
        }
        await clearTask?.value
    }

    func startup() async {
        guard !started else { return }; started = true
        invalidateRenumber()
        let epoch = lifecycleEpoch
        let token = UUID(); operation = token; busy = true; recovering = true
        // Only this namespace's unlocked, provenance-marked crash leftovers.
        // A cleanup failure must not prevent recovery of the current count.
        await Task.detached(priority: .utility) { try? TransientDirectory.removeOrphans() }.value
        guard operation == token, isLive(epoch) else { return }
        do {
            let recovered = try await store.load(epoch: epoch)
            #if DEBUG
            try await qaBoundary("startupCompletion")
            #endif
            if let recovered, operation == token, isLive(epoch) {
                candidate = recovered.candidate; snapshot = recovered.snapshot
                history = MarkerHistory(markers: recovered.snapshot.markers)
                recoveryMessage = "Current count saved on this device"
            }
        } catch { if operation == token, isLive(epoch) { self.error = "Couldn’t recover the current count. \(error.localizedDescription)" } }
        guard operation == token, isLive(epoch) else { return }; busy = false; recovering = false
        #if DEBUG
        if candidate == nil, ProcessInfo.processInfo.environment["DOTCOUNTER_QA_DENSE"] == "1" {
            do {
                let fixture = try await NativeQAFixture.makeImage()
                await preparePhoto(fixture, filename: "QA-24MP.jpg")
                if let snapshot, let candidate {
                    let markers = NativeQAFixture.markers
                    let doc = CountDocument(image: candidate.identity, markers: markers)
                    history = MarkerHistory(markers: markers)
                    self.snapshot = RecoverySnapshot(workspaceID: snapshot.workspaceID, revision: snapshot.revision + 1, sourceToken: snapshot.sourceToken, image: snapshot.image, markers: markers, baselineDigest: doc.contentDigest)
                    await flush()
                }
                try? FileManager.default.removeItem(at: fixture)
            } catch { self.error = "QA fixture failed: \(error.localizedDescription)" }
        }
        // Explicit simulator/Mac QA only; absent during ordinary launches.
        if candidate == nil, ProcessInfo.processInfo.environment["DOTCOUNTER_QA_FIXTURE"] == "1", let url = Bundle.main.url(forResource: "QA-flock", withExtension: "jpg") { await preparePhoto(url, filename: ProcessInfo.processInfo.environment["DOTCOUNTER_QA_FILENAME"]) }
        if let path = ProcessInfo.processInfo.environment["DOTCOUNTER_QA_IMAGE"], candidate == nil {
            await preparePhoto(URL(fileURLWithPath: path))
        }
        #endif
    }
    func cancelOpening() { guard !committing, !clearing else { return }; operation = UUID(); busy = false; if let pending { Self.discardCandidate(pending.0) }; pending = nil }
    // Native picker completions share this admission/publication path with controlled transfers.
    func receivePhotoTransfer(_ request: Request, isCurrent: () -> Bool,
                              load: () async throws -> PickedPhoto?) async {
        guard isLive(request.epoch), isCurrent() else { return }
        invalidateRenumber()
        do {
            guard let photo = try await load() else { throw CocoaError(.fileReadUnknown) }
            defer { withExtendedLifetime(photo) {} }
            #if DEBUG
            try await qaBoundary("photoTransferCompletion")
            #endif
            guard isLive(request.epoch), isCurrent() else { return }
            try Task.checkCancellation()
            await preparePhoto(photo.url, requestEpoch: request.epoch)
        } catch {
            if isLive(request.epoch), isCurrent() { self.error = "Couldn’t open the selected photo. \(error.localizedDescription)" }
        }
    }
    func receiveFileResult(_ result: Result<[URL], Error>, request: Request, json: Bool) async {
        func current() -> Bool { isLive(request.epoch) && (json ? jsonRequest : filesRequest) == request }
        guard current() else { return }
        do {
            #if DEBUG
            try await qaBoundary(json ? "jsonPickerCompletion" : "filesPickerCompletion")
            #endif
            guard current() else { return }
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    if json { await prepareJSON(url, requestEpoch: request.epoch) }
                    else { await preparePhoto(url, requestEpoch: request.epoch) }
                }
            case .failure(let failure): throw failure
            }
        } catch {
            if current() { self.error = json ? "This marker file can’t be opened. \(error.localizedDescription)" : "Couldn’t open the selected photo. \(error.localizedDescription)" }
        }
    }
    func preparePhoto(_ url: URL, filename: String? = nil, requestEpoch: UUID? = nil) async {
        let epoch = requestEpoch ?? lifecycleEpoch
        guard isLive(epoch), !committing else { return }
        invalidateRenumber()
        invalidateBirdDetection()
        #if DEBUG
        NativeQARecorder.shared.beganLocalOpen(active: candidate != nil && !recovering)
        #endif
        let token = UUID(); operation = token; busy = true
        do {
            let image = try await ImageService.prepare(url: url, filename: filename)
            #if DEBUG
            do { try await qaBoundary("photoPrepareCompletion") }
            catch { Self.discardCandidate(image); throw error }
            #endif
            guard operation == token, isLive(epoch) else { Self.discardCandidate(image); return }
            busy = false
            if let pairing {
                guard pairing.image.matches(image.identity) else {
                    Self.discardCandidate(image); error = "This isn’t the original photo. The selected file has changed. Choose the unchanged original or a copy saved by DotCounter. Your current count is unchanged."; showPairing = true; return
                }
                await offer(image, document: pairing, epoch: epoch)
            } else { await offer(image, document: CountDocument(image: image.identity, markers: []), epoch: epoch) }
        } catch { guard operation == token, isLive(epoch) else { return }; busy = false; self.error = "Couldn’t open \(url.lastPathComponent). \(error.localizedDescription)" }
    }
    func prepareJSON(_ url: URL, requestEpoch: UUID? = nil) async {
        let epoch = requestEpoch ?? lifecycleEpoch
        guard isLive(epoch), !committing else { return }
        invalidateRenumber()
        invalidateBirdDetection()
        let token = UUID(); operation = token; busy = true
        do {
            let doc = try await Task.detached {
                let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                var coordinationError: NSError?
                var read: Result<CountDocument, Error>?
                NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { readable in
                    read = Result { try CountDocument.decode(BoundedFileReader.read(readable, maximumBytes: ResourceLimits.maxJSONBytes)) }
                }
                if let coordinationError { throw coordinationError }
                guard let read else { throw CocoaError(.fileReadUnknown) }
                return try read.get()
            }.value
            #if DEBUG
            try await qaBoundary("jsonDecodeCompletion")
            #endif
            guard operation == token, isLive(epoch) else { return }; busy = false; pairing = doc; showPairing = true
        } catch { guard operation == token, isLive(epoch) else { return }; busy = false; self.error = "This marker file can’t be opened. \(error.localizedDescription)" }
    }
    func useCurrentPhoto(requestEpoch: UUID? = nil) async {
        let epoch = requestEpoch ?? lifecycleEpoch
        guard isLive(epoch), !committing, let candidate, let pairing, candidate.identity.matches(pairing.image) else { return }
        invalidateRenumber()
        await offer(candidate, document: pairing, epoch: epoch)
    }
    private func offer(_ image: ImageCandidate, document: CountDocument, epoch: UUID) async {
        guard isLive(epoch), !committing else { Self.discardCandidate(image); return }
        if let pending { Self.discardCandidate(pending.0) }; pending = (image, document); showPairing = false
        if dirty { showReplacement = true } else { await replace(requestEpoch: epoch) }
    }
    func cancelReplacement() { if let pending { Self.discardCandidate(pending.0) }; pending = nil; showReplacement = false; pairing = nil }
    func replace(requestEpoch: UUID? = nil) async {
        let epoch = requestEpoch ?? lifecycleEpoch, nextEpoch = UUID()
        guard isLive(epoch), !committing, let (image, doc) = pending else { return }
        invalidateRenumber()
        busy = true; committing = true; showReplacement = false
        // The main actor is frozen for the final serialized recovery barrier.
        do {
            await saveTask?.value
            guard isLive(epoch) else { return }
            let commit = try await store.replace(candidate: image, document: doc, workspaceID: UUID(), baselineDigest: doc.contentDigest, epoch: epoch, newEpoch: nextEpoch)
            lifecycleEpoch = nextEpoch; detailRequested = nil; clearTarget = nil; clearFailed = false
            exportShown = false; exportCapture = nil
            candidate = ImageCandidate(sourceURL: commit.sourceURL, identity: commit.snapshot.image, preview: image.preview)
            snapshot = commit.snapshot; history = MarkerHistory(markers: doc.markers)
            selectedID = nil; mode = .count; fitCommand += 1
            recoveryStale = commit.durabilityWarning != nil
            recoveryMessage = commit.durabilityWarning ?? "Current count saved on this device"
            Self.discardCandidate(image); pending = nil; pairing = nil
            #if DEBUG
            NativeQARecorder.shared.committedLocalOpen(revision: commit.snapshot.revision, total: total)
            #endif
        } catch { self.error = "Couldn’t replace this count. Your current count is unchanged. \(error.localizedDescription)" }
        busy = false; committing = false
    }
    func deselect() { guard !clearing else { return }; selectedID = nil }
    func changeMode(_ value: Mode) { guard !clearing, !busy, !exportShown else { return }; mode = value }
    func tap(_ point: CGPoint, hit: UUID?) {
        guard !busy, !clearing, !exportShown else { return }
        if birdReview != nil { if birdDraftMode { let moving=birdMovingDraft;editBirdReview { if let moving {$0.moveDraft(moving,x:point.x,y:point.y)} else{$0.addDraft(x:point.x,y:point.y)} };birdMovingDraft=nil };return }
        if let hit { selectedID = hit } else if mode == .count { guard markers.count < ResourceLimits.maxMarkers else { error = "This count has reached the 100,000-marker limit. Export it before starting another count."; return }; edit { $0.add(x: point.x, y: point.y) }; selectedID = nil } else { selectedID = nil }
    }
    func move(_ id: UUID, to point: CGPoint) { guard !busy, !clearing, !exportShown else { return }; edit { $0.move(id: id, x: point.x, y: point.y) } }
    func remove() { guard mode == .edit, let selectedID, !busy, !clearing else { return }; edit { $0.delete(id: selectedID) }; self.selectedID = nil }
    func undo() { edit { $0.undo() }; sanitizeSelection() }
    func redo() { edit { $0.redo() }; sanitizeSelection() }
    var canRenumber: Bool { candidate != nil && snapshot != nil && total >= 2 && !busy && !clearing && !committing && !exportShown }
    func renumber(_ order: RenumberOrder) {
        guard canRenumber else { return }
        if order == .nearestNeighbor { nearestNeighbor() }
        else { edit { $0.renumber(order) } }
    }

    /// Revoke publication immediately. The active worker retains ownership until
    /// it drains; only one replaceable newest capture can wait behind it.
    func invalidateRenumber() {
        renumberEligible = nil; renumberPending = false; renumberProgress = false
        renumberFailure = false; renumberTimer?.cancel(); renumberTimer = nil
        renumberActive?.control.cancel(); renumberNewest?.control.cancel(); renumberNewest = nil
    }
    func cancelRenumber() { invalidateRenumber() }
    private func nearestNeighbor() {
        guard canRenumber, let snapshot else { return }
        invalidateRenumber()
        guard snapshot.revision < UInt64.max else { error = "This count has reached its edit limit. Export JSON and reopen it."; return }
        setConnectionsVisible(true)
        invalidateBirdDetection()
        let request = NearestRequest(epoch: lifecycleEpoch, snapshot: snapshot, history: history)
        renumberEligible = request.id; renumberPending = true; renumberNewest = request
        renumberTimer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self, self.renumberEligible == request.id else { return }
            self.renumberProgress = true
        }
        startNewestRenumber()
    }
    private func renumberIsCurrent(_ request: NearestRequest) -> Bool {
        guard renumberEligible == request.id, lifecycleEpoch == request.epoch,
              canRenumber, let snapshot, let candidate else { return false }
        return snapshot.workspaceID == request.snapshot.workspaceID && snapshot.sourceToken == request.snapshot.sourceToken
            && snapshot.revision == request.snapshot.revision && snapshot.image == request.snapshot.image
            && candidate.identity == request.snapshot.image
    }
    private func startNewestRenumber() {
        guard renumberActive == nil, let request = renumberNewest else { return }
        renumberNewest = nil; renumberActive = request
        renumberTask = Task { [weak self] in
            do {
                // Preparation runs explicitly outside the main actor, including
                // permutation validation, history construction and snapshot creation.
                let prepared = try await Task.detached(priority: .userInitiated) {
                    let indices = try NearestNeighborRoute.indices(markers: request.history.markers,
                        pixelWidth: request.snapshot.image.pixelWidth, pixelHeight: request.snapshot.image.pixelHeight,
                        cancellation: request.control)
                    var history = request.history
                    let changed = try history.applyPermutation(indices, cancellation: request.control)
                    try request.control.checkCancellation()
                    let next: RecoverySnapshot? = changed ? RecoverySnapshot(workspaceID: request.snapshot.workspaceID,
                        revision: request.snapshot.revision + 1, sourceToken: request.snapshot.sourceToken,
                        image: request.snapshot.image, markers: history.markers, baselineDigest: request.snapshot.baselineDigest) : nil
                    return (history, next)
                }.value
                guard let self else { return }
                if let next = prepared.1, self.renumberIsCurrent(request) {
                    try await self.prepareRenumberDrawing?(prepared.0.markers, next, request.control)
                }
                #if DEBUG
                try await self.qaBoundary("renumberCompletion")
                #endif
                if self.renumberIsCurrent(request) {
                    if let next = prepared.1 {
                        self.invalidateBirdDetection()
                        self.history = prepared.0; self.snapshot = next
                        self.didCommitEdit()
                    }
                    self.finishRenumber(request)
                }
            } catch {
                if let self, self.renumberIsCurrent(request) {
                    self.finishRenumber(request)
                    if !(error is CancellationError) { self.renumberFailure = true }
                }
            }
            guard let self, self.renumberActive?.id == request.id else { return }
            self.renumberActive = nil; self.renumberTask = nil
            self.startNewestRenumber()
        }
    }
    private func finishRenumber(_ request: NearestRequest) {
        guard renumberEligible == request.id else { return }
        renumberEligible = nil; renumberPending = false; renumberProgress = false
        renumberTimer?.cancel(); renumberTimer = nil
    }
    #if DEBUG
    var qaRenumberTask: Task<Void, Never>? { renumberTask }
    var qaRenumberQueued: Bool { renumberNewest != nil }
    #endif
    func appendBirdBatch(_ batch:[Marker]) { edit { $0.appendBatch(markers:batch) } }
    private func sanitizeSelection() { if !markers.contains(where: { $0.id == selectedID }) { selectedID = nil } }
    private func edit(_ action: (inout MarkerHistory) -> Bool) {
        guard candidate != nil, !busy, !clearing, !exportShown else { return }
        invalidateRenumber()
        guard (snapshot?.revision ?? 0) < UInt64.max else { error = "This count has reached its edit limit. Export JSON and reopen it."; return }
        invalidateBirdDetection()
        let state = signposter.beginInterval("Committed edit")
        guard action(&history) else { signposter.endInterval("Committed edit", state); return }
        if let snapshot { guard snapshot.revision < UInt64.max else { error = "This count has reached its edit limit. Export JSON and reopen it."; return }; self.snapshot = RecoverySnapshot(workspaceID: snapshot.workspaceID, revision: snapshot.revision + 1, sourceToken: snapshot.sourceToken, image: snapshot.image, markers: markers, baselineDigest: snapshot.baselineDigest) }
        signposter.endInterval("Committed edit", state)
        didCommitEdit()
    }
    private func didCommitEdit() {
        #if DEBUG
        if let snapshot { NativeQARecorder.shared.committed(revision: snapshot.revision, total: total) }
        #endif
        scheduleSave()
    }
    func scheduleSave() {
        guard snapshot != nil, !clearing else { return }
        recoveryMessage = "Saving current count…"
        guard saveTask == nil else { return }
        let epoch = lifecycleEpoch, job = UUID(); saveJob = job
        saveTask = Task {
            while isLive(epoch), let target = self.snapshot {
                do {
                    let commit = try await store.save(snapshot: target, epoch: epoch)
                    #if DEBUG
                    try await qaBoundary("saveCompletion")
                    #endif
                    if isLive(epoch), self.snapshot?.workspaceID == target.workspaceID, self.snapshot?.revision == target.revision {
                        recoveryStale = commit.durabilityWarning != nil
                        recoveryMessage = commit.durabilityWarning ?? "Current count saved on this device"
                        break
                    }
                } catch {
                    if isLive(epoch), self.snapshot?.workspaceID == target.workspaceID { recoveryStale = true; recoveryMessage = error.localizedDescription }
                    break
                }
            }
            #if DEBUG
            try? await qaBoundary("saveFinalizer")
            #endif
            if saveJob == job { saveTask = nil; saveJob = nil }
        }
    }
    func acquireSourceLease(_ token: UUID) async throws -> URL { try await store.acquireSourceLease(token: token) }
    func releaseSourceLease(_ token: UUID) async { await store.releaseSourceLease(token: token) }
    func requestDetail() {
        let epoch = lifecycleEpoch
        guard !clearing, let snapshot, let candidate, detailRequested != snapshot.workspaceID,
              max(candidate.identity.pixelWidth, candidate.identity.pixelHeight) > max(candidate.preview.width, candidate.preview.height) else { return }
        detailRequested = snapshot.workspaceID
        let task = Task {
            do {
                let source = try await acquireSourceLease(snapshot.sourceToken)
                guard isLive(epoch) else { await releaseSourceLease(snapshot.sourceToken); return }
                do {
                    let image = try await ImageService.preview(sourceURL: source, maxPixel: max(candidate.identity.pixelWidth, candidate.identity.pixelHeight))
                    #if DEBUG
                    try await qaBoundary("detailCompletion")
                    #endif
                    if isLive(epoch), self.snapshot?.workspaceID == snapshot.workspaceID { self.candidate = ImageCandidate(sourceURL: source, identity: candidate.identity, preview: image) }
                } catch { if isLive(epoch), self.snapshot?.workspaceID == snapshot.workspaceID { self.error = "Couldn’t load closer photo detail. \(error.localizedDescription)"; detailRequested = nil } }
                await releaseSourceLease(snapshot.sourceToken)
            } catch { if isLive(epoch), self.snapshot?.workspaceID == snapshot.workspaceID { self.error = error.localizedDescription; detailRequested = nil } }
        }
        #if DEBUG
        qaDetailTask = task
        #endif
    }
    func flush() async {
        if clearing { await clearTask?.value; return }
        scheduleSave(); await saveTask?.value
    }
    private nonisolated static func discardCandidate(_ image: ImageCandidate) {
        let url = image.sourceURL
        guard url.deletingLastPathComponent().lastPathComponent == "DotCounter-Candidates",
              url.pathExtension == "blob", UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }
    func recordJSONExport(_ digest: String, workspace: UUID, requestEpoch: UUID? = nil) {
        guard isLive(requestEpoch ?? lifecycleEpoch), let snapshot, snapshot.workspaceID == workspace, snapshot.revision < UInt64.max else { return }
        invalidateRenumber()
        invalidateBirdDetection()
        self.snapshot = RecoverySnapshot(workspaceID: snapshot.workspaceID, revision: snapshot.revision + 1, sourceToken: snapshot.sourceToken, image: snapshot.image, markers: markers, baselineDigest: digest); scheduleSave()
    }
}
