import Foundation
import DotCounterCore

enum BirdActivity: Equatable { case idle, preparing, running(Int,Int), review, failed }

extension Workspace {
    var birdPrototypeEnabled: Bool {
        #if DEBUG || OWNER_BETA || PUBLIC_STORE
        true
        #else
        false
        #endif
    }
    var canDetectBirds: Bool { birdPrototypeEnabled && candidate != nil && !busy && !clearing && !exportShown && !birdOwner && birdReview == nil }
    var birdCurrent: BirdSuggestion? { guard !clearing, let r=birdReview,r.suggestions.indices.contains(r.current) else{return nil};return r.suggestions[r.current] }
    var canApplyBirds: Bool {
        guard !clearing, let r=birdReview,matchesBirdKey(r.key),r.eligible,r.phase == .summary,r.pending==0,r.accepted+r.drafts.count>0,
              r.accepted+r.drafts.count<=10_000,r.accepted+r.drafts.count<=ResourceLimits.maxMarkers-total else{return false};return true
    }
    func matchesBirdKey(_ key:BirdDetectionKey) -> Bool {
        !clearing && key.generation==birdGeneration && birdKey==key && snapshot?.workspaceID==key.workspace && snapshot?.sourceToken==key.source && snapshot?.revision==key.revision && candidate?.identity==key.image
    }
    func invalidateBirdDetection(message:String = "") {
        birdGeneration=UUID();birdControl?.cancel();birdDeadline?.cancel();birdDeadline=nil;birdKey=nil;birdReview=nil;birdTargetReady=nil;birdDraftMode=false;birdShowOthers=false
        birdActivity = .idle;birdMessage=message
    }
    func startBirdDetection() {
        guard canDetectBirds,let candidate,let snapshot else{return}
        guard let model=Bundle.main.url(forResource:"CountGDFixedBird800ValidMaxFP32",withExtension:"mlpackage",subdirectory:"BirdPrototype") else{birdActivity = .failed;birdMessage="The prototype detector is not bundled in this build. Manual counting is available.";return}
        let control=BirdScanControl()
        birdGeneration=UUID()
        let key=BirdDetectionKey(workspace:snapshot.workspaceID,source:snapshot.sourceToken,generation:birdGeneration,image:candidate.identity,revision:snapshot.revision)
        let committed=markers
        birdKey=key;birdControl=control;birdOwner=true;birdActivity = .preparing;birdMessage="Local prototype · Suggestions need review. Existing markers are kept."
        birdDeadline=Task {
            #if DEBUG
            if let wait = qaBirdDeadlineWait { await wait() }
            else { try? await Task.sleep(for: .seconds(60)) }
            #else
            try? await Task.sleep(for: .seconds(60))
            #endif
            guard !Task.isCancelled,matchesBirdKey(key),birdReview==nil else{return}
            invalidateBirdDetection(message:BirdDetectionError.deadline.localizedDescription);birdActivity = .failed
        }
        birdTask=Task {
            var lease:URL?
            do {
                let source=try await acquireSourceLease(key.source);lease=source
                guard matchesBirdKey(key) else{throw BirdDetectionError.canceled}
                let suggestions: [BirdSuggestion]
                let measurement: BirdScanMeasurement?
                #if DEBUG
                if let scan = qaBirdScan {
                    suggestions = try await scan(key) { [weak self] done, total in await self?.publishBirdProgress(key, done: done, total: total) }
                    measurement = nil
                } else {
                    let result = try await scanBirdSource(source, model: model, key: key, committed: committed, control: control)
                    guard result.key == key else { throw BirdDetectionError.canceled }
                    suggestions = result.suggestions; measurement = result.measurement
                }
                #else
                let result = try await scanBirdSource(source, model: model, key: key, committed: committed, control: control)
                guard result.key == key else { throw BirdDetectionError.canceled }
                suggestions = result.suggestions; measurement = result.measurement
                #endif
                try control.check()
                guard matchesBirdKey(key) else{throw BirdDetectionError.canceled}
                birdReview=try BirdReview(key:key,suggestions:suggestions,eligible:true);birdMeasurement=measurement
                birdActivity = .review;birdMessage=suggestions.isEmpty ? "No birds were suggested. Birds may still be present; inspect the photo manually.":"Suggestions need your review. Your committed count is unchanged."
                birdDeadline?.cancel();birdDeadline=nil;birdCenterCommand += 1;birdTargetReady=nil
                if suggestions.isEmpty{fitCommand += 1}
            } catch {
                if matchesBirdKey(key){invalidateBirdDetection(message:error.localizedDescription);birdActivity = .failed}
            }
            if lease != nil {await releaseSourceLease(key.source)}
            // Owner remains reserved until synchronous work, model teardown and lease release finish.
            #if DEBUG
            try? await qaBoundary("birdFinalizer")
            #endif
            birdOwner=false;birdControl=nil;birdTask=nil
        }
    }
    private func scanBirdSource(_ source: URL, model: URL, key: BirdDetectionKey, committed: [Marker], control: BirdScanControl) async throws -> BirdScanResult {
        try await Task.detached(priority: .userInitiated) {
            try await BirdDetectionExecutor.shared.scan(source: source, modelURL: model, key: key, markers: committed, control: control) { done, total in
                Task { @MainActor [weak self] in await self?.publishBirdProgress(key, done: done, total: total) }
            }
        }.value
    }
    private func publishBirdProgress(_ key: BirdDetectionKey, done: Int, total: Int) async {
        #if DEBUG
        try? await qaBoundary("birdProgress")
        #endif
        guard matchesBirdKey(key), birdReview == nil else { return }
        birdActivity = .running(done, total)
    }
    func editBirdReview(_ change:(inout BirdReview)->Void) {
        guard !clearing, var r=birdReview,matchesBirdKey(r.key) else{return};change(&r);birdReview=r;birdDraftMode=false;birdTargetReady=nil;birdCenterCommand += 1
        if r.phase != .guided {fitCommand += 1}
    }
    func decideBird(_ value:BirdDecision,target:String,epoch:UInt64) {
        guard birdTargetReady==epoch else{return}
        editBirdReview { _ = $0.decide(value,target:target,epoch:epoch) }
    }
    func applyBirds() {
        guard canApplyBirds,let review=birdReview,let snap=snapshot,snap.revision<UInt64.max else{return}
        do {
            let batch=try review.additions(existing:markers)
            guard matchesBirdKey(review.key) else{return}
            // The existing edit transaction publishes precisely one batch/revision/save.
            appendBirdBatch(batch)
        } catch{self.error=error.localizedDescription}
    }
}
