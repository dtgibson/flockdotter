#if DEBUG
import SwiftUI
import QuartzCore
import DotCounterCore
import ImageIO
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Opt-in simulator/development-Mac evidence. No Release code or product controls.
/// A display-link boundary after matching native draw/layout revisions is a
/// presentation opportunity, not proof of physical-panel scanout.
@MainActor final class NativeQARecorder: NSObject {
    static let shared = NativeQARecorder()
    private(set) var enabled: Bool
    private let launched = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var pending: (action: String, start: Double, revision: UInt64?, total: Int?, commit: Double?)?
    private var canvas: (revision: UInt64, total: Int, finished: Double)?
    private var total: (revision: UInt64, total: Int, finished: Double)?
    private var imageSize: [Int] = []
    private var samples: [[String: Any]] = []
    private var committedRevisions: [UInt64] = []
    private var overwrittenCommitted: [UInt64] = []
    private var unmatchedCommitted: [UInt64] = []
    private var draws: [Double] = []
    private var warm: [String: Any]?
    private var navigationStart: Double?
    private var navigationTicks: [Double] = []
    private var navigationDraws: [Double] = []
    private var navigationInputs: [[String: Any]] = []
    private var navigationFinished = false
    var navigationDriver: ((Double) -> Void)?
    private var localOpenStart: Double?
    private var localOpenTarget: (revision: UInt64, total: Int, committed: Double)?
    private(set) var activeWarmFileOpens: [[String: Any]] = []
    private var files: [[String: Any]] = []
    private let writer = DispatchQueue(label: "app.dotcounter.qa-evidence")
    private var output: URL?
    override init() {
        let env = ProcessInfo.processInfo.environment
        enabled = env["DOTCOUNTER_QA_RECORD"] == "1" && UUID(uuidString: env["DOTCOUNTER_QA_SESSION"] ?? "") != nil
        if enabled, let session = env["DOTCOUNTER_QA_SESSION"] {
            output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("DotCounter-QA/\(session)/metrics.json")
        } else { output = nil }
        super.init()
        if let output {
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
    }
    func begin(_ action: String, timestamp: Double? = nil) {
        guard enabled else { return }
        if let revision = pending?.revision { overwrittenCommitted.append(revision) }
        pending = (action, timestamp ?? CACurrentMediaTime(), nil, nil, nil)
    }
    func activateHostedTest(output: URL) { enabled = true; self.output = output }
    func deactivateHostedTest() { enabled = false; displayLink?.invalidate(); displayLink = nil; navigationDriver = nil }
    func beganLocalOpen(active: Bool) {
        guard enabled, active else { return }
        localOpenStart = CACurrentMediaTime(); localOpenTarget = nil
    }
    func committedLocalOpen(revision: UInt64, total: Int) {
        guard enabled, localOpenStart != nil else { return }
        localOpenTarget = (revision, total, CACurrentMediaTime())
    }
    func committed(revision: UInt64, total: Int) {
        guard enabled else { return }
        committedRevisions.append(revision)
        guard pending != nil else { unmatchedCommitted.append(revision); return }
        pending?.revision = revision; pending?.total = total; pending?.commit = CACurrentMediaTime()
    }
    func drewCanvas(revision: UInt64, total: Int, image: [Int], started: Double) {
        guard enabled else { return }
        let now = CACurrentMediaTime(), duration = (now - started) * 1000
        canvas = (revision, total, now); imageSize = image; draws.append(duration)
        if let navigationStart, now - navigationStart <= 10 { navigationDraws.append(duration) }
    }
    func drewTotalGlyphs(revision: UInt64, total: Int) {
        guard enabled else { return }
        self.total = (revision, total, CACurrentMediaTime())
    }
    #if os(iOS)
    func attach(_ view: UIView) {
        guard enabled, displayLink == nil, view.window != nil else { return }
        displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }
    #else
    func attach(_ view: NSView) {
        guard enabled, displayLink == nil, view.window != nil else { return }
        displayLink = view.displayLink(target: self, selector: #selector(tick(_:)))
        displayLink?.add(to: .main, forMode: .common)
    }
    #endif
    func navigation(kind: String = "native adapter") {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        if let start = navigationStart, now - start <= 10 {
            navigationInputs.append(["seconds": now - start, "kind": kind])
        }
        guard navigationStart == nil else { return }
        navigationStart = CACurrentMediaTime()
        navigationInputs.append(["seconds": 0, "kind": kind])
        Task { try? await Task.sleep(for: .seconds(10.1)); navigationFinished = true; publish() }
    }
    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if let start = navigationStart, now - start <= 10 {
            navigationTicks.append(now - start)
            if let navigationDriver {
                navigationDriver(now - start)
                navigationInputs.append(["seconds": now - start, "kind": "DEBUG display-link driver through production CanvasEngine.pan/zoom"])
            }
        }
        guard let canvas, let total, canvas.revision == total.revision, canvas.total == total.total else { return }
        if let start = localOpenStart, let target = localOpenTarget,
           target.revision == canvas.revision, target.total == canvas.total,
           canvas.finished >= target.committed, total.finished >= target.committed {
            activeWarmFileOpens.append(["preparePhotoToOpportunityMs": (now - start) * 1000, "total": canvas.total, "imagePixels": imageSize, "scope": "active app local-file prepare/copy/hash/decode + recovery replacement + native glyph/canvas draw + display-link opportunity; picker user navigation excluded"])
            localOpenStart = nil; localOpenTarget = nil; publish()
        }
        if warm == nil, imageSize == [6000, 4000], canvas.total == 1000 {
            warm = ["appInitToOpportunityMs": (now - launched) * 1000, "revision": canvas.revision, "total": canvas.total, "imagePixels": imageSize]
            publish()
        }
        if let event = pending, let revision = event.revision, revision == canvas.revision, event.total == canvas.total, let commit = event.commit {
            samples.append(["action": event.action, "revision": revision, "total": canvas.total,
                            "nativeActionToCommitMs": (commit - event.start) * 1000,
                            "nativeActionToTotalGlyphDrawMs": (total.finished - event.start) * 1000,
                            "nativeActionToCanvasDrawMs": (canvas.finished - event.start) * 1000,
                            "nativeActionToPresentationOpportunityMs": (now - event.start) * 1000,
                            "displayLinkTimestamp": link.timestamp, "displayLinkTargetTimestamp": link.targetTimestamp])
            pending = nil
            if samples.count % 10 == 0 { publish() }
        }
    }
    func saved(kind: String, destination: URL, scoped: Bool) {
        guard enabled else { return }
        files.append(["kind": kind, "destination": destination.path, "securityScopeGranted": scoped])
        publish()
    }
    func publish() {
        guard enabled, let output else { return }
        let payload: [String: Any] = [
            "measurement": "native action → matching native total glyph draw + canvas draw → next display-link presentation opportunity; not physical-panel timing",
            "configuration": "Debug", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "imagePixels": imageSize, "warmProcessRecovery": warm ?? [:], "samples": samples,
            "activeWarmFileOpens": activeWarmFileOpens,
            "committedRevisions": committedRevisions, "overwrittenCommittedRevisions": overwrittenCommitted, "unmatchedCommittedRevisions": unmatchedCommitted,
            "timingLimits": "Native glyph/canvas draw issuance and display-link opportunity, not physical scanout. Canvas spans are wall time. Other cadence gaps remain unclassified; no automatic host/app attribution.",
            "canvasDrawMs": draws, "navigation": ["requestedSeconds": 10, "finished": navigationFinished, "displayLinkSeconds": navigationTicks, "canvasDrawMs": navigationDraws, "inputEvents": navigationInputs],
            "savedOutputs": files
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        writer.async {
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
            } catch { print("DotCounter QA evidence write failed: \(error)") }
        }
    }
}

enum NativeQAFixture {
    static func makeImage() async throws -> URL {
        try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("DotCounter-QA-24MP-\(UUID().uuidString).jpg")
            let space = CGColorSpaceCreateDeviceRGB()
            guard let context = CGContext(data: nil, width: 6000, height: 4000, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileReadTooLarge) }
            context.setFillColor(CGColor(red: 0.72, green: 0.79, blue: 0.83, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 6000, height: 4000))
            for row in 0..<40 { for column in 0..<60 {
                context.setFillColor(CGColor(gray: CGFloat((column + row) % 4) / 4 + 0.1, alpha: 1))
                context.fillEllipse(in: CGRect(x: column * 100 + 30, y: row * 100 + 30, width: 30, height: 14))
            } }
            guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
            return url
        }.value
    }
    static var markers: [Marker] {
        (0..<1000).map { Marker(id: UUID(), x: (Double($0 % 50) + 0.5) / 50, y: (Double($0 / 50) + 0.5) / 20) }
    }
}
#endif
