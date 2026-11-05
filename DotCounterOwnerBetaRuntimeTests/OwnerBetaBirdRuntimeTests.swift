#if OWNER_BETA
import XCTest
import Foundation
import DotCounterCore

final class OwnerBetaBirdRuntimeTests:XCTestCase,@unchecked Sendable {
    func testOptimizedOwnerBetaNativeService()async throws {
        #if DEBUG
        XCTFail("OwnerBeta runtime evidence must not use DEBUG")
        #endif
        let source=try XCTUnwrap(Bundle(for:Self.self).url(forResource:"OwnerBeta-bird-fixture",withExtension:"jpg"))
        XCTAssertNil(Bundle.main.url(forResource:"OwnerBeta-bird-fixture",withExtension:"jpg"),"Research photo belongs only in the local test bundle")
        let model=try XCTUnwrap(Bundle.main.url(forResource:"CountGDFixedBird800ValidMaxFP32",withExtension:"mlpackage",subdirectory:"BirdPrototype"))
        let notices=try XCTUnwrap(Bundle.main.url(forResource:"Third-party-notices",withExtension:"txt",subdirectory:"BirdPrototype"))
        XCTAssertTrue(try String(contentsOf:notices,encoding:.utf8).contains("Copyright (c) 2024 Niki Amini-Naieni"))
        let candidate=try await ImageService.inspectExisting(url:source,filename:"blackbird-sunset.jpg")
        XCTAssertEqual(candidate.identity.sha256,"6bf5b999781f3342b01a4821ca5a30da4365658258e7245cc050457d88ca1fdc")
        let key=BirdDetectionKey(workspace:UUID(),source:UUID(),generation:UUID(),image:candidate.identity,revision:0),control=BirdScanControl(),headroom=BirdDetectionExecutor.memoryHeadroom()
        var receipt:[String:Any]=["scope":"Optimized OwnerBeta iPhone simulator app-hosted native service; no DEBUG or app QA hooks; reused photo only in test bundle; no accuracy/human/hardware claim","runtime_policy":BirdMemoryHeadroom.runtimePolicy,"headroom_metric":headroom.metric.rawValue,"prestart_headroom_bytes":headroom.bytes,"headroom_required_bytes":BirdMemoryHeadroom.requiredBytes,"source_sha256":key.image.sha256,"model_tree_sha256":key.modelTree,"contract_sha256":key.contract,"run_uuid":key.run.uuidString,"app_bundle":Bundle.main.bundleIdentifier ?? "unavailable"]
        do {
            let result=try await BirdDetectionExecutor.shared.scan(source:source,modelURL:model,key:key,markers:[],control:control){_,_ in}
            XCTAssertEqual(result.key,key);XCTAssertLessThanOrEqual(result.measurement.calls,20)
            receipt["status"]="complete_eligible_service_result";receipt["suggestions"]=result.suggestions.count;receipt["calls"]=result.measurement.calls;receipt["accepted_start_through_complete_seconds"]=result.measurement.seconds;receipt["baseline_rss"]=result.measurement.baselineRSS;receipt["maximum_sampled_rss"]=result.measurement.maximumSampledRSS;receipt["scan_headroom_bytes"]=result.measurement.headroom.bytes
        } catch {receipt["status"]="failed_ineligible";receipt["message"]=error.localizedDescription}
        let duration=control.started.duration(to:.now);receipt["start_through_drain_seconds"]=Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18
        let data=try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys])
        let proof=XCTAttachment(data:data,uniformTypeIdentifier:"public.json");proof.name="Optimized OwnerBeta reused-photo native service outcome";proof.lifetime = .keepAlways;add(proof)
        print("OWNER_BETA_RUNTIME "+String(data:data,encoding:.utf8)!)
        XCTAssertEqual(receipt["status"] as? String,"complete_eligible_service_result","This probe measures actual optimized completion; a safe refusal is retained as a failed runtime probe, never relaxed")
    }
}
#endif
