import Foundation
import CoreML
import CoreGraphics
import ImageIO
import Darwin
import os
import CryptoKit

/// Cancellation is independent of the serial executor: synchronous Core ML may
/// drain after eligibility is revoked. No second owner is admitted during drain.
public final class BirdScanControl: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    public let started:ContinuousClock.Instant
    public init(started:ContinuousClock.Instant = .now) {self.started=started}
    public func cancel() { lock.lock();revoked=true;lock.unlock() }
    public func check() throws {
        lock.lock();let canceled=revoked;lock.unlock()
        if canceled || Task.isCancelled { throw BirdDetectionError.canceled }
        if ContinuousClock.now-started >= .seconds(60) { throw BirdDetectionError.deadline }
    }
}

public struct BirdScanMeasurement: Sendable {
    public let calls: Int, seconds: Double, baselineRSS: UInt64, maximumSampledRSS: UInt64
    public let headroom:BirdMemoryHeadroom
}
public struct BirdScanResult: Sendable {
    public let key: BirdDetectionKey
    public let suggestions: [BirdSuggestion]
    public let measurement: BirdScanMeasurement
}

public actor BirdDetectionExecutor {
    public static let shared = BirdDetectionExecutor()
    private init() {}
    /// Called from a detached task. The body never suspends while model resources exist.
    public func scan(source: URL, modelURL: URL, key: BirdDetectionKey, markers: [Marker], control: BirdScanControl,
                     progress: @Sendable (Int,Int) -> Void) throws -> BirdScanResult {
        try autoreleasepool {
            var queue=try BirdDetectionPolicy.roots(width:key.image.pixelWidth,height:key.image.pixelHeight)
            try control.check()
            let base=Self.residentBytes();var peak=base
            let headroom=Self.memoryHeadroom()
            guard headroom.sufficient else { throw BirdDetectionError.unavailable("Not enough memory headroom for this local prototype. Continue counting manually.") }
            let monitor=DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:.global(qos:.utility))
            monitor.setEventHandler { control.cancel() };monitor.resume();defer{monitor.cancel()}
            func checkpoint() throws {
                try control.check();let rss=Self.residentBytes();peak=max(peak,rss)
                guard rss<=base+2048*1024*1024 else {throw BirdDetectionError.unavailable("Detection exceeded its memory guard. Your count is unchanged.")}
            }
            let bytes=(try source.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max
            guard bytes<=256*1024*1024,try ImageService.hashFile(source)==key.image.sha256 else {throw BirdDetectionError.invalidOutput}
            try checkpoint()
            try Self.verifyPackage(modelURL,control:control)
            let raster=try BirdSourceRaster(url:source,identity:key.image)
            try checkpoint()
            let configuration=MLModelConfiguration();configuration.computeUnits = .cpuOnly
            let compiled: URL
            if modelURL.pathExtension == "mlmodelc" {compiled=modelURL}
            else {
                let cache=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0]
                let values=try cache.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey])
                guard (values.volumeAvailableCapacityForImportantUsage ?? 0)>=1536*1024*1024 else {throw BirdDetectionError.unavailable("Detection needs 1.5 GB of free cache space.")}
                compiled=try MLModel.compileModel(at:modelURL)
            }
            defer { if compiled != modelURL {try? FileManager.default.removeItem(at:compiled)} }
            guard try Self.directoryBytes(compiled)<=650*1024*1024 else {throw BirdDetectionError.unavailable("The compiled detector exceeds its resource budget.")}
            try checkpoint()
            let model=try MLModel(contentsOf:compiled,configuration:configuration)
            guard let input=model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint,
                  input.dataType == .float32,input.shape.map(\.intValue)==[1,3,800,800] else {throw BirdDetectionError.invalidOutput}
            var suggestions:[BirdSuggestion]=[],executed=0,rawTotal=0
            while !queue.isEmpty {
                try checkpoint()
                guard executed<20 else{throw BirdDetectionError.capacity}
                let tile=queue.removeFirst()
                let output=try autoreleasepool { () throws -> (rawCount:Int,suggestions:[BirdSuggestion]) in
                    let tensor=try raster.tensor(tile:tile,control:control)
                    try checkpoint()
                    let provider=try MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(multiArray:tensor)])
                    let result=try model.prediction(from:provider)
                    try checkpoint()
                    guard let b=result.featureValue(for:"boxes")?.multiArrayValue,
                          let l=result.featureValue(for:"logits")?.multiArrayValue,
                          b.dataType == .float32,l.dataType == .float32,
                          b.shape.map(\.intValue)==[1,900,4],l.shape.map(\.intValue)==[1,900,256],b.count==3600,l.count==230400 else {throw BirdDetectionError.invalidOutput}
                    // MLMultiArray subscripting respects noncontiguous strides.
                    let boxes=(0..<b.count).map{b[$0].floatValue},logits=(0..<l.count).map{l[$0].floatValue}
                    return try BirdOutput.decode(boxes:boxes,logits:logits,tile:tile,key:key,markers:markers)
                }
                executed += 1;rawTotal += output.rawCount
                guard rawTotal<=50_000 else{throw BirdDetectionError.capacity}
                if output.rawCount==900 {
                    let children=try tile.children()
                    guard executed+queue.count+children.count<=20 else{throw BirdDetectionError.capacity}
                    queue.append(contentsOf:children)
                } else {suggestions.append(contentsOf:output.suggestions)}
                guard suggestions.count<=10_000 else{throw BirdDetectionError.capacity}
                try checkpoint();progress(executed,executed+queue.count)
            }
            try checkpoint()
            let duration=control.started.duration(to:.now)
            return BirdScanResult(key:key,suggestions:suggestions.sorted(by:BirdSuggestion.ordered),measurement:BirdScanMeasurement(calls:executed,seconds:Double(duration.components.seconds)+Double(duration.components.attoseconds)/1e18,baselineRSS:base,maximumSampledRSS:peak,headroom:headroom))
        }
    }
    private static func directoryBytes(_ url:URL) throws -> Int {
        guard let files=FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey]) else{throw BirdDetectionError.invalidOutput}
        var total=0
        for case let file as URL in files {let v=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]);if v.isRegularFile==true{total += v.fileSize ?? 0}}
        return total
    }
    private static func verifyPackage(_ url:URL,control:BirdScanControl) throws {
        guard url.pathExtension=="mlpackage" else{throw BirdDetectionError.invalidOutput}
        let expected:[(String,Int,String)]=[
            ("Data/com.apple.CoreML/model.mlmodel",1452252,"f6b855fc50f09946cd729baf872d0ea16b4856012bbaadeb02f7c597ce02e70e"),
            ("Data/com.apple.CoreML/weights/weight.bin",539500736,"a3e4fca75edf170997708921427f774f902ee4fe472dbe49e92073d79ce4a159"),
            ("Manifest.json",617,"61eb37008e84449018aa93d05d830167ca4779e546481bb5b7a87fe19759870a")]
        guard try directoryBytes(url)==540953605 else{throw BirdDetectionError.invalidOutput}
        for (path,bytes,digest) in expected {
            let file=url.appendingPathComponent(path),values=try file.resourceValues(forKeys:[.fileSizeKey,.isSymbolicLinkKey])
            guard values.fileSize==bytes,values.isSymbolicLink != true else{throw BirdDetectionError.invalidOutput}
            let handle=try FileHandle(forReadingFrom:file);defer{try? handle.close()};var hash=SHA256()
            while let data=try handle.read(upToCount:1024*1024),!data.isEmpty{try control.check();hash.update(data:data)}
            guard hash.finalize().map({String(format:"%02x",$0)}).joined()==digest else{throw BirdDetectionError.invalidOutput}
        }
    }
    public nonisolated static func residentBytes() -> UInt64 {
        var info=mach_task_basic_info();var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let status=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)}}
        return status==KERN_SUCCESS ? info.resident_size:0
    }
    public nonisolated static func memoryHeadroom() -> BirdMemoryHeadroom {
        #if os(iOS) && !targetEnvironment(simulator)
        return BirdMemoryHeadroom(metric:.iosProcessLimit,processBytes:UInt64(os_proc_available_memory()),hostBytes:0)
        #else
        var info=vm_statistics64();var count=mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size/MemoryLayout<integer_t>.size)
        let host=mach_host_self();defer{mach_port_deallocate(mach_task_self_,host)}
        let status=withUnsafeMutablePointer(to:&info){p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)){host_statistics64(host,HOST_VM_INFO64,$0,&count)}}
        var page:vm_size_t=0;let pageStatus=host_page_size(host,&page)
        // Match HOST_VM_INFO64_REV0_COUNT: older kernels need not return newer
        // SDK tail fields; free/inactive pages are in the original prefix.
        let minimumCount=MemoryLayout<vm_statistics64>.offset(of:\.decompressions).map{mach_msg_type_number_t($0/MemoryLayout<integer_t>.size)}
        let bytes=BirdMemoryHeadroom.hostBytes(freePages:UInt64(info.free_count),inactivePages:UInt64(info.inactive_count),pageBytes:UInt64(page),queriesSucceeded:status==KERN_SUCCESS && pageStatus==KERN_SUCCESS && minimumCount.map{count >= $0} == true)
        #if targetEnvironment(simulator)
        return BirdMemoryHeadroom(metric:.simulatorHost,processBytes:0,hostBytes:bytes)
        #else
        return BirdMemoryHeadroom(metric:.macHost,processBytes:0,hostBytes:bytes)
        #endif
        #endif
    }
}

/// Holds one raw-orientation RGBA decode, not a second full upright raster.
/// The decoder's backing plus this surface are included in the 8-byte/pixel allowance.
public struct BirdSourceRaster {
    private var pixels:[UInt8] = []
    private let width:Int,height:Int,inverse:CGAffineTransform
    public init(url:URL,identity:ImageIdentity) throws {
        guard let source=CGImageSourceCreateWithURL(url as CFURL,[kCGImageSourceShouldCache:false] as CFDictionary) else{throw BirdDetectionError.invalidOutput}
        let index=CGImageSourceGetPrimaryImageIndex(source)
        let props=CGImageSourceCopyPropertiesAtIndex(source,index,nil) as? [CFString:Any]
        let orientation=(props?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        guard (1...8).contains(orientation),let image=CGImageSourceCreateImageAtIndex(source,index,[kCGImageSourceShouldCache:false] as CFDictionary),
              (orientation>=5 ? image.height:image.width)==identity.pixelWidth,(orientation>=5 ? image.width:image.height)==identity.pixelHeight else{throw BirdDetectionError.invalidOutput}
        width=image.width;height=image.height
        inverse=ImageService.orientationTransform(orientation,width:CGFloat(width),height:CGFloat(height)).inverted()
        var data=[UInt8](repeating:0,count:width*height*4)
        let made=data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx=CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else{return false}
            ctx.draw(image,in:CGRect(x:0,y:0,width:width,height:height));return true
        }
        guard made else{throw BirdDetectionError.unavailable("The source crop could not be decoded within available memory.")};pixels=data
    }
    public func tensor(tile:BirdTile,control:BirdScanControl) throws -> MLMultiArray {
        let array=try MLMultiArray(shape:[1,3,800,800],dataType:.float32)
        let p=array.dataPointer.bindMemory(to:Float.self,capacity:array.count)
        let means:[Double]=[0.485,0.456,0.406],std:[Double]=[0.229,0.224,0.225]
        for row in 0..<800 {
            if row%32==0{try control.check()}
            for col in 0..<800 {
                let sx=tile.squareX+(Double(col)+0.5)*tile.side/800,sy=tile.squareY+(Double(row)+0.5)*tile.side/800
                var rgb=[Double](repeating:0,count:3)
                if tile.logical.contains(x:sx,y:sy) {
                    // Pixel-center inverse affine handles all eight EXIF/mirror cases.
                    let integral = tile.logical.x.rounded()==tile.logical.x && tile.logical.y.rounded()==tile.logical.y && tile.logical.width.rounded()==tile.logical.width && tile.logical.height.rounded()==tile.logical.height
                    let sampleX=integral ? max(tile.logical.x+0.5,min(tile.logical.x+tile.logical.width-0.5,sx)):sx
                    let sampleY=integral ? max(tile.logical.y+0.5,min(tile.logical.y+tile.logical.height-0.5,sy)):sy
                    let raw=CGPoint(x:sampleX,y:sampleY).applying(inverse),fx=raw.x-0.5,fy=raw.y-0.5
                    let ix=Int(floor(fx)),iy=Int(floor(fy)),dx=fx-Double(ix),dy=fy-Double(iy)
                    for oy in 0...1 {for ox in 0...1 {
                        let x=ix+ox,y=iy+oy
                        guard x>=0,y>=0,x<width,y<height else{continue}
                        let upright=CGPoint(x:Double(x)+0.5,y:Double(y)+0.5).applying(inverse.inverted())
                        guard tile.logical.contains(x:upright.x,y:upright.y) else{continue}
                        let weight=(ox==0 ? 1-dx:dx)*(oy==0 ? 1-dy:dy)
                        for c in 0..<3 {rgb[c] += Double(pixels[(y*width+x)*4+c])*weight/255}
                    }}
                }
                for c in 0..<3 {p[c*640000+row*800+col]=Float((rgb[c]-means[c])/std[c])}
            }
        }
        return array
    }
}
