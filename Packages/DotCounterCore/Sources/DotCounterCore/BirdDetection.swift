import Foundation

public enum BirdDetectionError: LocalizedError, Sendable {
    case unavailable(String), invalidOutput, saturated, capacity, deadline, canceled
    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        case .invalidOutput: "The detector returned invalid data. No suggestions were added."
        case .saturated: "This photo is too dense for the bounded detector. Continue counting manually."
        case .capacity: "This scan exceeds the prototype’s work or suggestion limit. Continue counting manually."
        case .deadline: "Detection did not finish within 60 seconds. No suggestions were added."
        case .canceled: "Detection canceled. Your count is unchanged."
        }
    }
}

public enum BirdDetectionPolicy {
    public static let contract = "4f12f9d9580589967010a96610ce926c8fa8d37d78c8082f68629a1b36b1e5c6"
    public static let modelTree = "0bf005710150e5a0b1f406fac13804a59e933f26fe941cd6dc02af027eaf3047"
    public static let review = "guided-review-v3-photo-check-no-confirmation"
    public static let maxCalls = 20, maxSuggestions = 10_000

    public static func roots(width: Int, height: Int) throws -> [BirdTile] {
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, pixels <= 24_000_000, max(width,height) <= 8192 else {
            throw BirdDetectionError.unavailable("The local detection prototype supports up to 24 MP and 8,192 pixels per edge. Manual counting is still available.")
        }
        func starts(_ length: Int) -> [Double] {
            if length <= 400 { return [0] }
            return Array(Set(stride(from: 0, through: length-400, by: 200).map(Double.init) + [Double(length-400)])).sorted()
        }
        let xs = starts(width), ys = starts(height)
        guard xs.count * ys.count <= maxCalls else { throw BirdDetectionError.capacity }
        func boundary(_ starts: [Double], _ index: Int, _ length: Int) -> Double {
            if index == 0 { return 0 }
            if index == starts.count { return Double(length) }
            return (starts[index-1] + starts[index]) / 2 + 200
        }
        var result: [BirdTile] = []
        for y in ys.indices { for x in xs.indices {
            result.append(BirdTile(id: "r\(result.count)", depth: 0,
                logical: BirdRect(x: xs[x], y: ys[y], width: 400, height: 400),
                owner: BirdRect(x: boundary(xs,x,width), y: boundary(ys,y,height), width: boundary(xs,x+1,width)-boundary(xs,x,width), height: boundary(ys,y+1,height)-boundary(ys,y,height))))
        } }
        return result
    }
}

public struct BirdRect: Equatable, Sendable {
    public let x, y, width, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
    public func contains(x px: Double, y py: Double) -> Bool { px >= x && py >= y && px < x+width && py < y+height }
}

public struct BirdTile: Equatable, Sendable {
    public let id: String
    public let depth: Int
    public let logical, owner: BirdRect
    public var side: Double { max(logical.width,logical.height) }
    public var squareX: Double { logical.x + (logical.width-side)/2 }
    public var squareY: Double { logical.y + (logical.height-side)/2 }
    public func children() throws -> [BirdTile] {
        guard depth == 0 else { throw BirdDetectionError.saturated }
        return try (0..<4).map { index in
            let w=owner.width/2, h=owner.height/2
            let cell=BirdRect(x: owner.x+Double(index%2)*w, y: owner.y+Double(index/2)*h, width:w,height:h)
            let rect=BirdRect(x:cell.x-w/2,y:cell.y-h/2,width:2*w,height:2*h)
            guard (200...400).contains(max(rect.width,rect.height)) else { throw BirdDetectionError.saturated }
            return BirdTile(id:id+".\(index)",depth:1,logical:rect,owner:cell)
        }
    }
}

public struct BirdDetectionKey: Equatable, Sendable {
    public let run: UUID, workspace: UUID, source: UUID, generation: UUID
    public let image: ImageIdentity
    public let revision: UInt64
    public let contract = BirdDetectionPolicy.contract, modelTree = BirdDetectionPolicy.modelTree
    public init(run: UUID = UUID(), workspace: UUID, source: UUID, generation: UUID, image: ImageIdentity, revision: UInt64) {
        self.run=run;self.workspace=workspace;self.source=source;self.generation=generation;self.image=image;self.revision=revision
    }
}

public struct BirdSuggestion: Identifiable, Equatable, Sendable {
    public let id: String
    public let x, y, width, height, score: Double
    public let nearLabel: Int?
    public init(id: String, x: Double, y: Double, width: Double, height: Double, score: Double, nearLabel: Int? = nil) {
        self.id=id;self.x=x;self.y=y;self.width=width;self.height=height;self.score=score;self.nearLabel=nearLabel
    }
    public func validate() throws {
        guard !id.isEmpty, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y), width.isFinite, height.isFinite, width>0, height>0, score.isFinite, (0...1).contains(score) else { throw BirdDetectionError.invalidOutput }
    }
    public static func ordered(_ a: Self, _ b: Self) -> Bool { if a.y != b.y { return a.y < b.y }; if a.x != b.x { return a.x < b.x };return a.id < b.id }
}

public enum BirdOutput {
    /// Validates every logit, including the masked tail. Content and ownership exclusions happen only after box validation.
    public static func decode(boxes: [Float], logits: [Float], tile: BirdTile, key: BirdDetectionKey, markers: [Marker]) throws -> (rawCount: Int, suggestions: [BirdSuggestion]) {
        guard boxes.count == 3600, logits.count == 230400 else { throw BirdDetectionError.invalidOutput }
        var count=0, result: [BirdSuggestion]=[]
        for q in 0..<900 {
            var best = -Double.infinity
            for t in 0..<256 {
                let v=Double(logits[q*256+t])
                guard !v.isNaN, v != .infinity, t>=4 || v.isFinite else { throw BirdDetectionError.invalidOutput }
                if t<4 { best=max(best,v) }
            }
            let score=1/(1+exp(-best))
            guard score > 0.23 else { continue };count += 1
            let b=(0..<4).map { Double(boxes[q*4+$0]) }
            guard b.allSatisfy(\.isFinite), (0...1).contains(b[0]), (0...1).contains(b[1]), b[2]>0,b[3]>0 else { throw BirdDetectionError.invalidOutput }
            let x=tile.squareX+b[0]*tile.side, y=tile.squareY+b[1]*tile.side, w=b[2]*tile.side,h=b[3]*tile.side
            guard x>=0,y>=0,x<Double(key.image.pixelWidth),y<Double(key.image.pixelHeight),tile.logical.contains(x:x,y:y),tile.owner.contains(x:x,y:y) else { continue }
            let radius=max(2,min(12,0.25*min(w,h)))
            var nearest: (distance: Double,label:Int)?
            for (i,marker) in markers.enumerated() {
                let d=hypot(x-marker.x*Double(key.image.pixelWidth),y-marker.y*Double(key.image.pixelHeight))
                if d<=radius, nearest == nil || d<nearest!.distance { nearest=(d,i+1) }
            }
            result.append(BirdSuggestion(id:"\(key.contract):\(key.run.uuidString):\(tile.id):\(q)",x:x/Double(key.image.pixelWidth),y:y/Double(key.image.pixelHeight),width:w,height:h,score:score,nearLabel:nearest?.label))
        }
        return (count,count==900 ? []:result)
    }
}

public enum BirdDecision: String, Sendable { case pending, accepted, rejected, skipped }
public enum BirdReviewPhase: Sendable { case guided, photoCheck, summary }
public struct BirdReview: Sendable {
    public let key: BirdDetectionKey
    public let suggestions: [BirdSuggestion]
    public let eligible: Bool
    public private(set) var decisions: [BirdDecision]
    public private(set) var current = 0
    public private(set) var epoch: UInt64 = 0
    public private(set) var phase: BirdReviewPhase = .guided
    public private(set) var drafts: [Marker] = []
    private enum Operation: Sendable { case decision(Int,BirdDecision);case skip([Int],Int,BirdReviewPhase) }
    private var operations: [Operation] = []
    public var pending: Int { decisions.filter{$0 == .pending}.count }
    public var accepted: Int { decisions.filter{$0 == .accepted}.count }
    public var rejected: Int { decisions.filter{$0 == .rejected}.count }
    public var skipped: Int { decisions.filter{$0 == .skipped}.count }
    public var reviewed: Int { accepted+rejected }
    public var canUndo: Bool { !operations.isEmpty }
    public var undoIsBulk: Bool { if case .skip = operations.last { return true };return false }
    public init(key: BirdDetectionKey, suggestions: [BirdSuggestion], eligible: Bool) throws {
        guard suggestions.count<=BirdDetectionPolicy.maxSuggestions,Set(suggestions.map(\.id)).count==suggestions.count else { throw BirdDetectionError.invalidOutput }
        for item in suggestions { try item.validate() }
        self.key=key; self.suggestions=suggestions.sorted(by:BirdSuggestion.ordered);self.eligible=eligible
        self.decisions=Array(repeating:.pending,count:suggestions.count)
        if suggestions.isEmpty { phase = .photoCheck }
    }
    public mutating func navigate(_ index: Int) { guard suggestions.indices.contains(index) else{return};current=index;phase = .guided;epoch &+= 1 }
    @discardableResult public mutating func decide(_ decision: BirdDecision, target: String, epoch: UInt64) -> Bool {
        guard phase == .guided, suggestions.indices.contains(current), suggestions[current].id==target, self.epoch==epoch,
              decision == .accepted || decision == .rejected,decisions[current] != decision else{return false}
        operations.append(.decision(current,decisions[current]));decisions[current]=decision;advance();return true
    }
    private mutating func advance() { if pending == 0 { phase = .photoCheck;epoch &+= 1;return };skipForNow() }
    public mutating func skipForNow() { guard !suggestions.isEmpty else{return};for offset in 1...suggestions.count { let i=(current+offset)%suggestions.count;if decisions[i] == .pending {current=i;break} };epoch &+= 1 }
    public mutating func skipAll() { let ids=decisions.indices.filter{decisions[$0] == .pending};guard !ids.isEmpty else{return};operations.append(.skip(ids,current,phase));for i in ids {decisions[i] = .skipped};phase = .photoCheck;epoch &+= 1 }
    public mutating func undo() { guard let op=operations.popLast() else{return};switch op {case let .decision(i,before):decisions[i]=before;current=i;phase = .guided;case let .skip(ids,cursor,oldPhase):for i in ids{decisions[i] = .pending};current=cursor;phase=oldPhase};epoch &+= 1 }
    public mutating func photoCheck() { guard pending==0 else{return};phase = .photoCheck;epoch &+= 1 }
    public mutating func summary() { guard pending==0, phase == .photoCheck else{return};phase = .summary;epoch &+= 1 }
    public mutating func addDraft(x: Double,y: Double) { let marker=Marker(x:x,y:y);guard (try? marker.validate()) != nil,drafts.count<10_000 else{return};drafts.append(marker) }
    public mutating func removeDraft(_ id: UUID) { drafts.removeAll{$0.id==id} }
    public mutating func moveDraft(_ id: UUID,x:Double,y:Double) { let p=Marker(id:id,x:x,y:y);guard (try? p.validate()) != nil,let i=drafts.firstIndex(where:{$0.id==id}) else{return};drafts[i]=p }
    public func additions(existing:[Marker]) throws -> [Marker] {
        guard eligible,phase == .summary,pending==0 else {throw BirdDetectionError.invalidOutput}
        let selected=suggestions.indices.filter{decisions[$0] == .accepted}.map{suggestions[$0]}
        let count=selected.count+drafts.count
        guard count>0,count<=10_000,count<=ResourceLimits.maxMarkers-existing.count else{throw BirdDetectionError.capacity}
        var points=selected.map{($0.id,$0.x,$0.y)}+drafts.map{($0.id.uuidString,$0.x,$0.y)}
        guard Set(points.map{$0.0}).count==points.count else{throw BirdDetectionError.invalidOutput}
        points.sort{a,b in if a.2 != b.2{return a.2<b.2};if a.1 != b.1{return a.1<b.1};return a.0<b.0}
        var ids=Set(existing.map(\.id))
        return try points.map { _,x,y in var id=UUID();while !ids.insert(id).inserted{id=UUID()};let m=Marker(id:id,x:x,y:y);try m.validate();return m }
    }
}
