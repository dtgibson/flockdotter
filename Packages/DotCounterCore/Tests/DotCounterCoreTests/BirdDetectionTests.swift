import XCTest
@testable import DotCounterCore

final class BirdDetectionTests:XCTestCase {
    private func key(width:Int=800,height:Int=533)->BirdDetectionKey {BirdDetectionKey(workspace:UUID(),source:UUID(),generation:UUID(),image:ImageIdentity(sha256:String(repeating:"a",count:64),pixelWidth:width,pixelHeight:height,originalFilename:"birds.jpg"),revision:7)}
    private func review(eligible:Bool=true)throws->BirdReview {try BirdReview(key:key(),suggestions:(0..<5).map{BirdSuggestion(id:"q\($0)",x:0.1+Double($0)/10,y:0.3,width:4,height:3,score:0.8,nearLabel:$0==0 ? 1:nil)},eligible:eligible)}
    func testBatchIsAtomicSingleHistoryAndStableRedo() {
        let original=Marker(x:0.2,y:0.4),batch=[Marker(x:0.3,y:0.7),Marker(x:0.8,y:0.9)]
        var h=MarkerHistory(markers:[original]);XCTAssertTrue(h.appendBatch(markers:batch));XCTAssertEqual(h.undoCount,1)
        XCTAssertTrue(h.undo());XCTAssertEqual(h.markers,[original]);XCTAssertTrue(h.redo());XCTAssertEqual(h.markers,[original]+batch)
        XCTAssertFalse(h.appendBatch(markers:[batch[0]]));XCTAssertEqual(h.undoCount,1)
        XCTAssertFalse(h.appendBatch(markers:[Marker(x:.nan,y:0.5)]));XCTAssertEqual(h.markers,[original]+batch)
        _=h.undo();_ = h.add(x:0.7,y:0.1);XCTAssertFalse(h.canRedo)
    }
    func testRootsExactlyPartitionAndBudgetBeforeWork()throws {
        let threshold=BirdMemoryHeadroom.requiredBytes
        let host=BirdMemoryHeadroom.hostBytes(freePages:65536,inactivePages:131072,pageBytes:16384,queriesSucceeded:true)
        XCTAssertEqual(host,3*1024*1024*1024)
        XCTAssertTrue(BirdMemoryHeadroom(metric:.simulatorHost,processBytes:0,hostBytes:host).sufficient)
        XCTAssertFalse(BirdMemoryHeadroom(metric:.iosProcessLimit,processBytes:0,hostBytes:host).sufficient,"Real iOS zero must never fall back to host RAM")
        XCTAssertFalse(BirdMemoryHeadroom(metric:.simulatorHost,processBytes:UInt64.max,hostBytes:threshold-1).sufficient,"Simulator still refuses genuine low host availability")
        XCTAssertTrue(BirdMemoryHeadroom(metric:.iosProcessLimit,processBytes:threshold,hostBytes:0).sufficient)
        XCTAssertEqual(BirdMemoryHeadroom.hostBytes(freePages:1,inactivePages:1,pageBytes:16384,queriesSucceeded:false),0)
        XCTAssertEqual(BirdMemoryHeadroom.hostBytes(freePages:1,inactivePages:1,pageBytes:0,queriesSucceeded:true),0)
        XCTAssertEqual(BirdMemoryHeadroom.hostBytes(freePages:.max,inactivePages:1,pageBytes:16384,queriesSucceeded:true),0)
        XCTAssertEqual(BirdMemoryHeadroom.hostBytes(freePages:.max,inactivePages:0,pageBytes:16384,queriesSucceeded:true),0)
        let roots=try BirdDetectionPolicy.roots(width:801,height:533)
        XCTAssertEqual(roots.count,8)
        for y in stride(from:0.25,to:533,by:17.25){for x in stride(from:0.25,to:801,by:19.75){XCTAssertEqual(roots.filter{$0.owner.contains(x:x,y:y)}.count,1)}}
        let children=try roots[0].children();XCTAssertEqual(children.count,4)
        XCTAssertEqual(children.reduce(0){$0+$1.owner.width*$1.owner.height},roots[0].owner.width*roots[0].owner.height)
        XCTAssertThrowsError(try children[0].children());XCTAssertThrowsError(try BirdDetectionPolicy.roots(width:6000,height:4000))
        XCTAssertEqual(try BirdDetectionPolicy.roots(width:1,height:1).count,1)
    }
    func testBulkSkipIncludesDeferredHonestCountsAndUndoKeepsDrafts()throws {
        var r=try review();XCTAssertEqual(r.pending,5);XCTAssertEqual(r.reviewed,0)
        r.skipForNow();let target=r.suggestions[r.current]
        XCTAssertTrue(r.decide(.accepted,target:target.id,epoch:r.epoch));r.skipAll()
        XCTAssertEqual(r.pending,0);XCTAssertEqual(r.skipped,4);XCTAssertEqual(r.reviewed,1);XCTAssertEqual(r.phase,.photoCheck)
        r.addDraft(x:0.25,y:0.6);r.summary();XCTAssertEqual(try r.additions(existing:[]).count,2)
        r.undo();XCTAssertEqual(r.pending,4);XCTAssertEqual(r.accepted,1);XCTAssertEqual(r.drafts.count,1);XCTAssertEqual(r.phase,.guided)
        XCTAssertThrowsError(try r.additions(existing:[]))
    }
    func testEpochNoRepeatPendingAndNoConfirmationGate()throws {
        var r=try review();let epoch=r.epoch,id=r.suggestions[r.current].id
        XCTAssertTrue(r.decide(.rejected,target:id,epoch:epoch));XCTAssertFalse(r.decide(.accepted,target:id,epoch:epoch))
        r.photoCheck();XCTAssertEqual(r.phase,.guided);r.summary();XCTAssertEqual(r.phase,.guided)
        r.skipAll();r.summary();XCTAssertEqual(r.phase,.summary)
        r.photoCheck();r.addDraft(x:0.5,y:0.5);r.summary();XCTAssertEqual(try r.additions(existing:[]).count,1)
        r.navigate(0);let p=r.suggestions[0];XCTAssertTrue(r.decide(.accepted,target:p.id,epoch:r.epoch));XCTAssertEqual(r.accepted,1)
    }
    func testBulkUndoMustFollowNewerDecisionsAndRecordedNeverApplies()throws {
        var r=try review();r.skipAll();r.navigate(0);let p=r.suggestions[0];_ = r.decide(.accepted,target:p.id,epoch:r.epoch)
        XCTAssertFalse(r.undoIsBulk);r.undo();XCTAssertEqual(r.skipped,5);XCTAssertTrue(r.undoIsBulk);r.undo();XCTAssertEqual(r.pending,5)
        var recorded=try review(eligible:false);recorded.skipAll();recorded.addDraft(x:0.1,y:0.2);recorded.summary();XCTAssertThrowsError(try recorded.additions(existing:[]))
    }
    func testTensorValidationOwnershipAndNearTie()throws {
        let k=key(width:400,height:400),tile=try BirdDetectionPolicy.roots(width:400,height:400)[0]
        var b=[Float](repeating:0,count:3600),l=[Float](repeating:-Float.infinity,count:230400)
        for q in 0..<900{for t in 0..<4{l[q*256+t] = -20}}
        b[0]=0.5;b[1]=0.5;b[2]=0.02;b[3]=0.02;l[0]=2
        let out=try BirdOutput.decode(boxes:b,logits:l,tile:tile,key:k,markers:[Marker(x:0.5,y:0.5),Marker(x:0.5,y:0.5)])
        XCTAssertEqual(out.rawCount,1);XCTAssertEqual(out.suggestions[0].nearLabel,1);XCTAssertEqual(out.suggestions[0].x,0.5)
        b[2] = .nan;XCTAssertThrowsError(try BirdOutput.decode(boxes:b,logits:l,tile:tile,key:k,markers:[]));b[2]=0.02;l[255] = .infinity
        XCTAssertThrowsError(try BirdOutput.decode(boxes:b,logits:l,tile:tile,key:k,markers:[]))
    }
    func testSaturatedParentDiscardsAllAndControlCancellation()throws {
        let k=key(width:400,height:400),tile=try BirdDetectionPolicy.roots(width:400,height:400)[0]
        let one:[Float]=[0.5,0.5,0.02,0.02]
        let b:[Float]=Array(repeating:one,count:900).flatMap{$0},l=[Float](repeating:2,count:230400)
        let out=try BirdOutput.decode(boxes:b,logits:l,tile:tile,key:k,markers:[]);XCTAssertEqual(out.rawCount,900);XCTAssertTrue(out.suggestions.isEmpty)
        let control=BirdScanControl();control.cancel();XCTAssertThrowsError(try control.check())
        XCTAssertThrowsError(try BirdScanControl(started:.now - .seconds(61)).check())
    }
}
