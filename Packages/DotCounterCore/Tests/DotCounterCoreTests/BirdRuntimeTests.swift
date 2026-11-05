import XCTest
import Foundation
@testable import DotCounterCore

final class BirdRuntimeTests:XCTestCase,@unchecked Sendable {
    private var project:URL {var p=URL(fileURLWithPath:#filePath);for _ in 0..<5{p.deleteLastPathComponent()};return p}
    func testRetainedCropInputParity()async throws {
        let corpus=project.appendingPathComponent("pipeline/automatic-bird-detection/feasibility/varied-evaluation/corpus/images/blackbird-sunset.jpg")
        let reference=project.appendingPathComponent("pipeline/automatic-bird-detection/feasibility/counting-models/native-evaluation/inputs/blackbird-sunset-context400.npy")
        guard FileManager.default.fileExists(atPath:reference.path) else{throw XCTSkip("Retained local research input is not present")}
        let candidate=try await ImageService.inspectExisting(url:corpus,filename:"blackbird-sunset.jpg")
        let tile=BirdTile(id:"parity",depth:0,logical:BirdRect(x:200,y:66,width:400,height:400),owner:BirdRect(x:200,y:66,width:400,height:400))
        let tensor=try BirdSourceRaster(url:corpus,identity:candidate.identity).tensor(tile:tile,control:BirdScanControl())
        let bytes=Data(bytes:tensor.dataPointer,count:tensor.count*4)
        try bytes.write(to:project.appendingPathComponent("pipeline/automatic-bird-detection/implementation/evidence/native-sunset-context400-input-f32.bin"))
        let data=try Data(contentsOf:reference);XCTAssertEqual(data.prefix(6),Data([147,78,85,77,80,89]))
        let header=Int(data[8])+Int(data[9])*256,start=10+header
        XCTAssertEqual(data.count-start,tensor.count*4)
        var maximum:Double=0,sum:Double=0
        data.withUnsafeBytes{raw in for i in 0..<tensor.count {let bits=raw.loadUnaligned(fromByteOffset:start+i*4,as:UInt32.self);let value=Float(bitPattern:UInt32(littleEndian:bits));let d=abs(Double(value-tensor[i].floatValue));maximum=max(maximum,d);sum += d}}
        print("BIRD_NATIVE_RASTER_PARITY max=\(maximum) mean=\(sum/Double(tensor.count))")
        // Characterized ImageIO vs Pillow JPEG decoding plus float-vs-byte resize
        // differs by up to 2.8125 RGB levels on this retained crop. This guard
        // catches sampling/geometry regressions; it is not bitwise input parity
        // or evidence that frozen model outputs can be borrowed by the app.
        XCTAssertLessThanOrEqual(maximum,3.5/255/0.224)
    }
    func testOptInNativeMacCompleteScanOutcome()async throws {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["DOTCOUNTER_BIRD_LIVE_PROBE"]=="1" else{throw XCTSkip("Explicit local native resource measurement only")}
        let source=project.appendingPathComponent("pipeline/automatic-bird-detection/feasibility/varied-evaluation/corpus/images/blackbird-sunset.jpg")
        let model=project.appendingPathComponent("pipeline/automatic-bird-detection/feasibility/counting-models/native/CountGDFixedBird800ValidMaxFP32.mlpackage")
        let candidate=try await ImageService.inspectExisting(url:source,filename:"blackbird-sunset.jpg")
        let key=BirdDetectionKey(workspace:UUID(),source:UUID(),generation:UUID(),image:candidate.identity,revision:0),control=BirdScanControl()
        var receipt:[String:Any]=["run_uuid":key.run.uuidString,"contract_sha256":key.contract,"source_sha256":key.image.sha256,"source_width":key.image.pixelWidth,"source_height":key.image.pixelHeight,"scope":"Development Mac native Core ML service XCTest, CPU_ONLY FP32; original reused photo; no app UI/minimum-OS/Intel/human accuracy or timing acceptance"]
        do {
            let result=try await BirdDetectionExecutor.shared.scan(source:source,modelURL:model,key:key,markers:[],control:control){_,_ in}
            receipt["status"]="complete_eligible_service_result";receipt["calls"]=result.measurement.calls;receipt["accepted_start_through_complete_seconds"]=result.measurement.seconds;receipt["baseline_rss"]=result.measurement.baselineRSS;receipt["maximum_sampled_rss"]=result.measurement.maximumSampledRSS;receipt["suggestions"]=result.suggestions.count
            receipt["positions"]=result.suggestions.map{["id":$0.id,"x":$0.x,"y":$0.y,"width":$0.width,"height":$0.height,"score":$0.score] as [String:Any]}
        } catch{receipt["status"]="failed_ineligible";receipt["failure"]=error.localizedDescription}
        let duration=control.started.duration(to:.now);receipt["start_through_drain_seconds"]=Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18
        let output=project.appendingPathComponent("pipeline/automatic-bird-detection/implementation/evidence/native-mac-scan-\(key.run.uuidString).json")
        try JSONSerialization.data(withJSONObject:receipt,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("BIRD_NATIVE_MAC_OUTCOME \(receipt["status"]!) receipt=\(output.lastPathComponent)")
        #else
        throw XCTSkip("Development Mac measurement")
        #endif
    }
}
