import Foundation

public enum BirdMemoryMetric:String,Sendable {
    case iosProcessLimit = "ios-process-dirty-limit-v1"
    case simulatorHost = "simulator-host-headroom-v1"
    case macHost = "mac-host-headroom-v1"
}

public struct BirdMemoryHeadroom:Sendable {
    public static let runtimePolicy = "owner-beta-runtime-v1"
    public static let requiredBytes:UInt64 = 2560*1024*1024
    public let metric:BirdMemoryMetric,bytes:UInt64
    public var sufficient:Bool {bytes>=Self.requiredBytes}
    public init(metric:BirdMemoryMetric,processBytes:UInt64,hostBytes:UInt64) {
        self.metric=metric;bytes=metric == .iosProcessLimit ? processBytes:hostBytes
    }
    public static func hostBytes(freePages:UInt64,inactivePages:UInt64,pageBytes:UInt64,queriesSucceeded:Bool)->UInt64 {
        guard queriesSucceeded,pageBytes>0 else{return 0}
        let (pages,sumOverflow)=freePages.addingReportingOverflow(inactivePages)
        let (bytes,productOverflow)=pages.multipliedReportingOverflow(by:pageBytes)
        return sumOverflow || productOverflow ? 0:bytes
    }
}
