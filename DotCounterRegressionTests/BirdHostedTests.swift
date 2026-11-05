import XCTest
import SwiftUI
import UIKit
import DotCounterCore
@testable import DotCounter

/// Hosted contract tests use synthetic locations only, never bird-accuracy judgments.
@MainActor final class BirdHostedTests:XCTestCase {
    private var root:URL!
    override func setUpWithError()throws{continueAfterFailure=false;root=FileManager.default.temporaryDirectory.appendingPathComponent("BirdHosted-\(UUID().uuidString)");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)}
    override func tearDownWithError()throws{try? FileManager.default.removeItem(at:root)}
    private func workspace()async throws->Workspace {
        let input=root.appendingPathComponent("synthetic.png")
        let image=UIGraphicsImageRenderer(size:CGSize(width:640,height:400)).image{ctx in UIColor.white.setFill();ctx.fill(CGRect(x:0,y:0,width:640,height:400))}
        try XCTUnwrap(image.pngData()).write(to:input)
        let w=Workspace(qaDirectory:root.appendingPathComponent("recovery"));await w.startup();await w.preparePhoto(input);return w
    }
    private func installReview(_ w:Workspace,eligible:Bool=true)throws {
        let snapshot=try XCTUnwrap(w.snapshot),image=try XCTUnwrap(w.candidate?.identity)
        let key=BirdDetectionKey(workspace:snapshot.workspaceID,source:snapshot.sourceToken,generation:w.birdGeneration,image:image,revision:snapshot.revision)
        w.birdKey=key;w.birdReview=try BirdReview(key:key,suggestions:(0..<4).map{BirdSuggestion(id:"synthetic-\($0)",x:0.2+Double($0)/10,y:0.4,width:3,height:3,score:0.8)},eligible:eligible);w.birdActivity = .review
        w.birdTargetReady=w.birdReview?.epoch
    }
    func testExplicitEntryInvalidationAndAtomicApplyUndoRecovery()async throws {
        let w=try await workspace();XCTAssertNil(w.birdReview);XCTAssertFalse(w.birdOwner);XCTAssertEqual(w.birdActivity,.idle)
        w.fitCommand += 1;w.zoomCommand += 1;XCTAssertNil(w.birdReview);XCTAssertNil(w.birdKey)
        w.startBirdDetection();XCTAssertTrue(w.birdOwner);let canceled=w.birdKey
        w.invalidateBirdDetection();XCTAssertTrue(w.birdOwner);XCTAssertNil(w.birdKey)
        w.startBirdDetection();XCTAssertNil(w.birdKey,"No second owner is queued while canceled work drains")
        w.tap(CGPoint(x:0.4,y:0.6),hit:nil);XCTAssertEqual(w.total,1,"Manual counting remains usable while draining")
        await w.birdTask?.value;XCTAssertFalse(w.birdOwner);XCTAssertNil(w.birdReview)
        if let canceled{XCTAssertFalse(w.matchesBirdKey(canceled))};w.undo()
        w.tap(CGPoint(x:0.1,y:0.1),hit:nil);let before=w.markers,revision=try XCTUnwrap(w.snapshot).revision
        try installReview(w);let r=try XCTUnwrap(w.birdReview);w.decideBird(.accepted,target:r.suggestions[0].id,epoch:r.epoch)
        w.editBirdReview{$0.skipAll()};w.editBirdReview{$0.addDraft(x:0.9,y:0.8)};w.editBirdReview{$0.summary()}
        XCTAssertTrue(w.canApplyBirds);XCTAssertEqual(w.total,1);w.applyBirds()
        XCTAssertEqual(w.total,3);XCTAssertEqual(w.snapshot?.revision,revision+1);XCTAssertNil(w.birdReview)
        let accepted=w.markers;w.applyBirds();XCTAssertEqual(w.markers,accepted)
        w.undo();XCTAssertEqual(w.markers,before);w.redo();XCTAssertEqual(w.markers,accepted)
        await w.flush();let restored=Workspace(qaDirectory:root.appendingPathComponent("recovery"));await restored.startup();XCTAssertEqual(restored.markers,accepted);XCTAssertNil(restored.birdReview)
        try installReview(w);let stale=try XCTUnwrap(w.birdKey);w.undo();XCTAssertFalse(w.matchesBirdKey(stale));XCTAssertNil(w.birdReview)
        try installReview(w);await w.preparePhoto(root.appendingPathComponent("absent.jpg"));XCTAssertNil(w.birdReview);XCTAssertEqual(w.markers,before)
        await w.flush()
    }
    func testRecordedCannotApplyAndStaleEpochCannotDecide()async throws {
        let w=try await workspace();try installReview(w,eligible:false);let r=try XCTUnwrap(w.birdReview)
        let engine=CanvasEngine(w),size=CGSize(width:393,height:400)
        engine.update(size:size);XCTAssertEqual(engine.viewport.scale,5,accuracy:0.00001)
        w.zoomCommand += 1;engine.update(size:size)
        XCTAssertEqual(engine.viewport.scale,6.55,accuracy:0.00001,"Toolbar inspection zoom must be retained")
        w.decideBird(.accepted,target:r.suggestions[0].id,epoch:r.epoch);w.decideBird(.accepted,target:r.suggestions[0].id,epoch:r.epoch)
        engine.update(size:size);XCTAssertEqual(engine.viewport.scale,6.55,accuracy:0.00001,"Accept must preserve toolbar zoom at the next target")
        XCTAssertEqual(w.birdReview?.accepted,1)
        let next=try XCTUnwrap(w.birdReview);w.birdTargetReady=next.epoch
        w.decideBird(.rejected,target:next.suggestions[next.current].id,epoch:next.epoch)
        engine.update(size:size);XCTAssertEqual(engine.viewport.scale,6.55,accuracy:0.00001,"Reject must preserve toolbar zoom at the next target")
        engine.zoom(0.8,at:CGPoint(x:size.width/2,y:size.height/2))
        let third=try XCTUnwrap(w.birdReview);w.birdTargetReady=third.epoch
        w.decideBird(.accepted,target:third.suggestions[third.current].id,epoch:third.epoch)
        engine.update(size:size);XCTAssertEqual(engine.viewport.scale,5.24,accuracy:0.00001,"Native gesture zoom must still persist")
        print("BIRD_QA_B01 toolbar=6.55 nextAccept=6.55 nextReject=6.55 nextGesture=\(engine.viewport.scale)")
        w.editBirdReview{$0.skipAll()};w.editBirdReview{$0.summary()}
        XCTAssertFalse(w.canApplyBirds);w.applyBirds();XCTAssertEqual(w.total,0)
        w.invalidateBirdDetection();XCTAssertNil(w.birdReview);XCTAssertNil(w.birdKey)
    }
    func testNativePhotoCheckHasDirectContinueAndDraftControls()async throws {
        let w=try await workspace();try installReview(w,eligible:false)
        let host=UIHostingController(rootView:WorkspaceView(workspace:w))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene);window.rootViewController=host;window.makeKeyAndVisible()
        window.frame=CGRect(x:0,y:0,width:393,height:852);host.view.frame=window.bounds;host.view.layoutIfNeeded();defer{window.isHidden=true}
        try await Task.sleep(for:.milliseconds(500))
        func findCanvas(_ view:UIView)->TouchCanvas? {if let canvas=view as? TouchCanvas{return canvas};return view.subviews.compactMap{findCanvas($0)}.first}
        let canvas=try XCTUnwrap(findCanvas(window))
        XCTAssertTrue(canvas.isFirstResponder,"Guided review must receive keyboard focus without a canvas tap")
        let field=UITextField(frame:CGRect(x:16,y:16,width:160,height:44));window.addSubview(field);field.becomeFirstResponder()
        canvas.updateReviewKeyboardFocus();XCTAssertTrue(field.isFirstResponder,"Review must not steal existing text/form focus")
        field.resignFirstResponder();field.removeFromSuperview();canvas.updateReviewKeyboardFocus();XCTAssertTrue(canvas.isFirstResponder)
        let modal=UIViewController();host.present(modal,animated:false)
        try await Task.sleep(for:.milliseconds(150))
        XCTAssertFalse(canvas.reviewKeyboardAvailable,"A presented modal must suppress review keys")
        canvas.resignFirstResponder();canvas.updateReviewKeyboardFocus();XCTAssertFalse(canvas.isFirstResponder)
        host.dismiss(animated:false);try await Task.sleep(for:.milliseconds(150))
        canvas.updateReviewKeyboardFocus();XCTAssertTrue(canvas.isFirstResponder)
        w.editBirdReview{$0.skipAll()};canvas.updateReviewKeyboardFocus()
        XCTAssertFalse(canvas.isFirstResponder);XCTAssertFalse(canvas.reviewKeyboardAvailable)
        host.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(150))
        let image=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
        let attachment=XCTAttachment(image:image);attachment.name="Native synthetic photo-check without checkbox";attachment.lifetime = .keepAlways;add(attachment)
        w.editBirdReview{$0.summary()};XCTAssertEqual(w.birdReview?.phase,.summary);XCTAssertFalse(w.canApplyBirds)
        XCTAssertEqual(w.birdReview?.skipped,4);XCTAssertEqual(w.birdReview?.reviewed,0)
    }
    func testLiveReusedSunsetScanRecordsActualOutcome()async throws {
        guard let researchRoot=ProcessInfo.processInfo.environment["DOTCOUNTER_RESEARCH_ROOT"] else{throw XCTSkip("Optional retained research corpus requires DOTCOUNTER_RESEARCH_ROOT")}
        let source=URL(fileURLWithPath:researchRoot).appendingPathComponent("feasibility/varied-evaluation/corpus/images/blackbird-sunset.jpg")
        guard FileManager.default.fileExists(atPath:source.path) else{throw XCTSkip("Optional retained research photograph is not present")}
        let w=Workspace(qaDirectory:root.appendingPathComponent("live-recovery"));await w.startup();await w.preparePhoto(source)
        let identity=try XCTUnwrap(w.candidate?.identity);XCTAssertNil(w.birdReview);XCTAssertFalse(w.birdOwner)
        let headroom=BirdDetectionExecutor.memoryHeadroom()
        XCTAssertEqual(headroom.metric,.simulatorHost)
        let before=w.markers,start=ContinuousClock.now;w.startBirdDetection();let run=w.birdKey?.run
        XCTAssertTrue(w.birdOwner);await w.birdTask?.value
        let duration=start.duration(to:.now)
        var result:[String:Any]=["source_sha256":identity.sha256,"source_width":identity.pixelWidth,"source_height":identity.pixelHeight,"contract_sha256":BirdDetectionPolicy.contract,"run_uuid":run?.uuidString ?? "unavailable","scope":"Native iPhone simulator app-hosted CPU_ONLY FP32; reused photo, not held-out/human evaluation","start_through_drain_seconds":Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18,"committed_count_unchanged":w.markers==before,"status":w.birdReview != nil ? "complete_eligible":"failed_ineligible","message":w.birdMessage]
        result["runtime_policy"]=BirdMemoryHeadroom.runtimePolicy;result["headroom_metric"]=headroom.metric.rawValue;result["prestart_headroom_bytes"]=headroom.bytes;result["headroom_required_bytes"]=BirdMemoryHeadroom.requiredBytes
        if let measurement=w.birdMeasurement {result["accepted_start_through_complete_seconds"]=measurement.seconds;result["calls"]=measurement.calls;result["baseline_rss"]=measurement.baselineRSS;result["maximum_sampled_rss"]=measurement.maximumSampledRSS;result["scan_headroom_bytes"]=measurement.headroom.bytes}
        if let review=w.birdReview {result["suggestions"]=review.suggestions.count;result["all_pending"]=review.pending==review.suggestions.count}
        let proof=XCTAttachment(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),uniformTypeIdentifier:"public.json");proof.name="Actual reused-photo native scan outcome";proof.lifetime = .keepAlways;add(proof)
        print("BIRD_NATIVE_SCAN_RESULT "+String(data:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),encoding:.utf8)!)
        XCTAssertEqual(w.markers,before);XCTAssertFalse(w.birdOwner)
        w.invalidateBirdDetection();await w.flush()
    }
    func testRecordedNativeReviewCaptures()async throws {
        guard let researchRoot=ProcessInfo.processInfo.environment["DOTCOUNTER_RESEARCH_ROOT"] else{throw XCTSkip("Optional retained research captures require DOTCOUNTER_RESEARCH_ROOT")}
        let base=URL(fileURLWithPath:researchRoot)
        let source=base.appendingPathComponent("feasibility/varied-evaluation/corpus/images/blackbird-sunset.jpg")
        let result=base.appendingPathComponent("feasibility/counting-models/native-evaluation/results/static800-cpu-v1/blackbird-sunset-context400-fp32.json")
        guard FileManager.default.fileExists(atPath:source.path),FileManager.default.fileExists(atPath:result.path) else{throw XCTSkip("Optional retained research photograph/results are not present")}
        let data=try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:result)) as? [String:Any]),rows=try XCTUnwrap(data["rows"] as? [[Double]])
        XCTAssertEqual(data["model_package_tree_sha256"] as? String,BirdDetectionPolicy.modelTree)
        let w=Workspace(qaDirectory:root.appendingPathComponent("recorded-recovery"));await w.startup();await w.preparePhoto(source)
        let snap=try XCTUnwrap(w.snapshot),image=try XCTUnwrap(w.candidate?.identity)
        XCTAssertEqual(data["source_sha256"] as? String,image.sha256)
        let key=BirdDetectionKey(workspace:snap.workspaceID,source:snap.sourceToken,generation:w.birdGeneration,image:image,revision:snap.revision)
        w.birdKey=key;w.birdReview=try BirdReview(key:key,suggestions:rows.enumerated().map{i,r in BirdSuggestion(id:"recorded-\(i)",x:r[0]/800,y:r[1]/533,width:r[2],height:r[3],score:r[4])},eligible:false);w.birdActivity = .review;w.birdCenterCommand += 1
        let host=UIHostingController(rootView:WorkspaceView(workspace:w)),scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene);window.rootViewController=host;window.makeKeyAndVisible();defer{window.isHidden=true}
        func capture(_ name:String)async throws {
            host.view.layoutIfNeeded();try await Task.sleep(for:.milliseconds(450))
            let image=UIGraphicsImageRenderer(bounds:window.bounds).image{_ in window.drawHierarchy(in:window.bounds,afterScreenUpdates:true)}
            let attachment=XCTAttachment(image:image);attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
        }
        try await capture("Native recorded crop guided review")
        let r=try XCTUnwrap(w.birdReview);w.birdTargetReady=r.epoch;w.decideBird(.accepted,target:r.suggestions[r.current].id,epoch:r.epoch)
        w.editBirdReview{$0.skipAll()};try await capture("Native recorded crop photo check")
        w.editBirdReview{$0.summary()};try await capture("Native recorded crop additions summary")
        XCTAssertFalse(w.canApplyBirds);XCTAssertEqual(w.total,0);XCTAssertEqual(w.birdReview?.accepted,1);XCTAssertEqual(w.birdReview?.skipped,461)
    }
}
