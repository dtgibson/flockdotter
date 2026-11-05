import SwiftUI
import DotCounterCore
import UniformTypeIdentifiers
import Observation
#if os(macOS)
import AppKit
#endif

/// Captured synchronously before presentation; SwiftUI reconstruction cannot replace its values.
struct ExportCapture: Identifiable {
    let id = UUID()
    let document: CountDocument
    let source: URL
    let workspaceID: UUID
    let initialTab: Int
    let sourceToken: UUID
    let requestEpoch: UUID
    let appearance: MarkerAppearance
    let connections: ConnectionPresentation
}

struct ExportView: View {
    let workspace: Workspace
    let capture: ExportCapture
    private var document: CountDocument { capture.document }
    private var source: URL { capture.source }
    private var workspaceID: UUID { capture.workspaceID }
    private var initialTab: Int { capture.initialTab }
    private var sourceToken: UUID { capture.sourceToken }
    private var requestEpoch: UUID { capture.requestEpoch }
    private var live: Bool { workspace.isLive(requestEpoch) && workspace.snapshot?.workspaceID == workspaceID }
    @State private var tab = 0
    @State private var png: URL?
    @State private var preview: CGImage?
    @State private var rendering = false
    @State var output = ExportSaveState()
    private var saving: Bool { output.saving }
    private var status: [String: String] { output.status }
    private var outputError: String? { output.error }
    @State private var folderPicker = false
    @Environment(\.dynamicTypeSize) private var textSize
    @Environment(\.dismiss) private var dismiss
    private var stem: String { (document.image.originalFilename as NSString).deletingPathExtension }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        if textSize.isAccessibilitySize {
                            Picker("Export format", selection: $tab) {
                                Text("Annotated Image").tag(0); Text("Editable Count").tag(1)
                            }.pickerStyle(.menu).frame(minHeight: 44)
                        } else {
                            Picker("Export format", selection: $tab) {
                                Text("Annotated Image").tag(0); Text("Editable Count").tag(1)
                            }.pickerStyle(.segmented)
                        }
                    }
                    if tab == 0 { annotated } else { editable }
                    if let outputError {
                        Text(outputError).foregroundStyle(Design.destructive).font(Design.font(13)).accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("exportOutputError")
                        if let retry = output.retry {
                            Button("Retry \(retry.kind)…") { chooseSave(retry.source, filename: retry.filename, kind: retry.kind) }.frame(minHeight: 44)
                        }
                    }
                    if saving { HStack { ProgressView(); Text("Saving…") } }
                }.padding(24)
            }.background(Design.surface).accessibilityIdentifier("exportContents").navigationTitle("Export count")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.buttonStyle(.plain).disabled(saving) } }
        }.buttonStyle(InstrumentButtonStyle()).font(Design.font()).foregroundStyle(Design.ink).tint(Design.accent).background(Design.surface)
            .preferredColorScheme(.light).instrumentSheet(width: 600, minimumHeight: 450)
            .task { tab = initialTab; await generatePNG() }
            .onDisappear { output.close() }
            .fileImporter(isPresented: $folderPicker, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                folderResult(result)
            }
    }
    private var annotated: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("The whole photo at full resolution. Your current zoom and selection aren’t included.")
            Text("\(document.markers.count) markers · \(capture.appearance.style.name) · \(capture.appearance.color.name)").font(Design.font(14, bold: true))
            Text(capture.connections.exportGuidance).font(Design.font(13)).foregroundStyle(Design.secondary)
            Text(capture.appearance.style.exportGuidance).font(Design.font(13)).foregroundStyle(Design.secondary)
            if let preview { Image(preview, scale: 1, label: Text("Actual generated PNG preview")).resizable().scaledToFit().frame(maxHeight: 340).accessibilityLabel("Actual generated PNG preview") }
            else if rendering { HStack { ProgressView(); Text("Preparing annotated PNG…") }.frame(height: 180) }
            else { Button("Retry PNG Preview") { Task { await generatePNG() } } }
            Text("\(document.markers.count) \(document.markers.count == 1 ? "bird" : "birds") marked · \(document.image.pixelWidth) × \(document.image.pixelHeight) · PNG").font(Design.font(13)).foregroundStyle(Design.secondary)
            Button("Save PNG…") { if let png { chooseSave(png, filename: "\(stem)-counted.png", kind: "PNG") } }.buttonStyle(InstrumentButtonStyle(primary: true)).frame(minHeight: 44).disabled(png == nil || saving)
            completion("PNG")
        }
    }
    private var editable: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep the marker data and the unchanged original photo together to edit this count later.")
            Label("\(stem).dotcounter.json", systemImage: "doc.text").font(Design.font(15, bold: true))
            Text("\(document.markers.count) markers · Ordered UUID coordinates").font(Design.font(13)).foregroundStyle(Design.secondary)
            Button("Save JSON…") { Task { await saveJSON() } }.buttonStyle(InstrumentButtonStyle(primary: true)).frame(minHeight: 44).disabled(saving)
            completion("JSON")
            Divider()
            Label(document.image.originalFilename, systemImage: "photo").font(Design.font(15, bold: true))
            Button(status["Original Photo"] == nil ? "Save Original Photo Copy…" : "Save Another Original Photo Copy…") { chooseSave(source, filename: document.image.originalFilename, kind: "Original Photo") }.frame(minHeight: 44).disabled(saving)
            completion("Original Photo")
            Text("An annotated PNG can’t reopen a count. Even a photo that looks identical won’t match if it has been edited or re-saved.").font(Design.font(13)).foregroundStyle(Design.secondary)
        }
    }
    @ViewBuilder private func completion(_ kind: String) -> some View { if let message = status[kind] { Label(message, systemImage: "checkmark.circle").font(Design.font(13)).foregroundStyle(Design.success).accessibilityAddTraits(.updatesFrequently) } }
    private func generatePNG() async {
        guard live, png == nil, !rendering, !output.closed else { return }; rendering = true
        workspace.invalidateBirdDetection(message:"Exports include committed markers only.")
        await workspace.birdTask?.value
        guard live, !output.closed else { rendering = false; return }
        do {
            let owner = try output.resources()
            defer { withExtendedLifetime(owner) {} }
            let leased = try await workspace.acquireSourceLease(sourceToken)
            guard live, !output.closed else { await workspace.releaseSourceLease(sourceToken); rendering = false; return }
            do {
                #if DEBUG
                try await workspace.qaBoundary("pngRender")
                #endif
                let url = try await ImageService.renderPNG(sourceURL: leased, document: document, directory: owner.url, appearance: capture.appearance, connections: capture.connections)
                var adopted = false
                defer { if !adopted { try? FileManager.default.removeItem(at: url) } }
                let image = try await ImageService.preview(sourceURL: url, maxPixel: 1800)
                if live, !output.closed, !Task.isCancelled { png = url; preview = image; output.error = nil; adopted = true }
            } catch { await workspace.releaseSourceLease(sourceToken); throw error }
            await workspace.releaseSourceLease(sourceToken)
        } catch { if live, !output.closed { output.error = "Couldn’t generate the PNG. \(error.localizedDescription)" } }
        rendering = false
    }
    private func saveJSON() async {
        guard live, !output.closed else { return }
        do {
            let owner = try output.resources()
            defer { withExtendedLifetime(owner) {} }
            let doc = document
            let url = try await Task.detached {
                let url = owner.url.appendingPathComponent("markers.json")
                if !FileManager.default.fileExists(atPath: url.path) { try doc.encoded().write(to: url, options: .atomic) }
                return url
            }.value
            if live, !output.closed, !Task.isCancelled { chooseSave(url, filename: "\(stem).dotcounter.json", kind: "JSON") }
        } catch { if live, !output.closed { output.error = "Couldn’t generate the JSON. \(error.localizedDescription)" } }
    }
    private func chooseSave(_ url: URL, filename: String, kind: String) {
        guard live, !output.closed else { return }
        let request = ExportSaveState.Request(source: url, filename: filename, kind: kind, owner: output.owner)
        output.begin(request)
        #if os(macOS)
        let panel = NSSavePanel(); panel.nameFieldStringValue = filename; panel.canCreateDirectories = true
        panel.title = "Save \(kind)"; panel.message = "Choose a new filename. DotCounter never overwrites an existing file."
        panel.begin { response in
            output.pending = nil
            if live, !output.closed, response == .OK, let destination = panel.url {
                Task { @MainActor in
                    await output.save(.init(request: request, url: destination, scopedFolder: nil), workspace: workspace, document: document, workspaceID: workspaceID, sourceToken: sourceToken, requestEpoch: requestEpoch)
                }
            }
        }
        #else
        #if DEBUG
        // Test the real callback/error UI without requiring a third-party provider.
        if let outcome = ProcessInfo.processInfo.environment["DOTCOUNTER_QA_PROVIDER_OUTCOME"] {
            if outcome == "cancel" { folderResult(.failure(CocoaError(.userCancelled))); return }
            if outcome == "failure" {
                folderResult(.failure(NSError(domain: "DotCounter.QAProvider", code: 503, userInfo: [NSLocalizedDescriptionKey: "Destination provider unavailable"]))); return
            }
        }
        #endif
        folderPicker = true
        #endif
    }
    private func folderResult(_ result: Result<[URL], Error>) {
        guard live, !output.closed else { return }
        if let destination = output.receiveFolderResult(result) {
            Task { await output.save(destination, workspace: workspace, document: document, workspaceID: workspaceID, sourceToken: sourceToken, requestEpoch: requestEpoch) }
        }
    }
}

/// The picker and the copy share one outcome state. Only a completed JSON copy
/// may update the workspace's exported baseline; choosing a folder never does.
@MainActor @Observable final class ExportSaveState {
    struct Request {
        let source: URL; let filename: String; let kind: String
        let owner: TransientDirectory?
        init(source: URL, filename: String, kind: String, owner: TransientDirectory? = nil) {
            self.source = source; self.filename = filename; self.kind = kind; self.owner = owner
        }
    }
    struct Destination { let request: Request; let url: URL; let scopedFolder: URL? }
    var saving = false
    var status: [String: String] = [:]
    var error: String?
    var pending: Request?
    var retry: Request?
    private(set) var closed = false
    private(set) var owner: TransientDirectory?
    func resources() throws -> TransientDirectory {
        guard !closed else { throw CancellationError() }
        if let owner { return owner }
        let created = try TransientDirectory(); owner = created; return created
    }
    func close() { closed = true; pending = nil; retry = nil; owner = nil }

    func begin(_ request: Request) { guard !closed else { return }; pending = request; retry = nil; error = nil }
    func receiveFolderResult(_ result: Result<[URL], Error>) -> Destination? {
        guard !closed, let request = pending else { return nil }
        pending = nil
        switch result {
        case .success(let urls):
            guard let folder = urls.first else {
                failed(request, error: CocoaError(.fileNoSuchFile)); return nil
            }
            return Destination(request: request, url: folder.appendingPathComponent(request.filename), scopedFolder: folder)
        case .failure(let failure):
            // UIDocumentPicker cancellation is Cocoa's explicit user-cancel code.
            // A provider's network-cancel/error is still a provider failure.
            let nsError = failure as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue { return nil }
            failed(request, error: failure); return nil
        }
    }
    func failed(_ request: Request, error failure: Error) {
        guard !closed else { return }
        retry = request
        let prefix = request.kind == "Original Photo" && status["JSON"] != nil ? "JSON was saved. The original photo copy failed." : "\(request.kind) could not be saved."
        error = "\(prefix) \(failure.localizedDescription) Choose a new filename or folder and retry."
    }
    func save(_ destination: Destination, workspace: Workspace, document: CountDocument, workspaceID: UUID, sourceToken: UUID? = nil, requestEpoch: UUID? = nil) async {
        let epoch = requestEpoch ?? workspace.lifecycleEpoch
        guard workspace.isLive(epoch), workspace.snapshot?.workspaceID == workspaceID, !closed else { return }
        defer { withExtendedLifetime(destination.request.owner) {} }
        saving = true
        let scope = destination.scopedFolder ?? destination.url
        let access = scope.startAccessingSecurityScopedResource()
        defer { if access { scope.stopAccessingSecurityScopedResource() }; saving = false }
        do {
            if destination.request.kind == "Original Photo", let sourceToken {
                let leased = try await workspace.acquireSourceLease(sourceToken)
                guard workspace.isLive(epoch), !closed else { await workspace.releaseSourceLease(sourceToken); return }
                do {
                    #if DEBUG
                    try await workspace.qaBoundary("exportCopy")
                    #endif
                    try await ImageService.noClobberCopy(from: leased, to: destination.url)
                }
                catch { await workspace.releaseSourceLease(sourceToken); throw error }
                await workspace.releaseSourceLease(sourceToken)
            } else { try await ImageService.noClobberCopy(from: destination.request.source, to: destination.url) }
            #if DEBUG
            try await workspace.qaBoundary("exportCompletion")
            #endif
            guard workspace.isLive(epoch), workspace.snapshot?.workspaceID == workspaceID, !closed else { return }
            #if DEBUG
            NativeQARecorder.shared.saved(kind: destination.request.kind, destination: destination.url, scoped: access)
            #endif
            let kind = destination.request.kind
            status[kind] = "\(kind) saved"
            if kind == "JSON" { workspace.recordJSONExport(document.contentDigest, workspace: workspaceID, requestEpoch: epoch) }
            error = nil; retry = nil
        } catch { if workspace.isLive(epoch), workspace.snapshot?.workspaceID == workspaceID { failed(destination.request, error: error) } }
    }
}
