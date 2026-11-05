import SwiftUI
import PhotosUI
import CoreTransferable
import UniformTypeIdentifiers
import DotCounterCore
#if os(iOS)
import UIKit
#endif

struct PickedPhoto: Transferable, Sendable {
    let url: URL
    let owner: TransientDirectory
    static func importFile(_ source: URL) throws -> PickedPhoto {
        let owner = try TransientDirectory()
        let url = owner.url.appendingPathComponent(source.lastPathComponent)
        try ImageService.copyAndHash(from: source, to: url)
        return PickedPhoto(url: url, owner: owner)
    }
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try importFile(received.file)
        }
    }
}

struct WorkspaceView: View {
    @Bindable var workspace: Workspace
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotos = false
    @State private var help = false
    @State private var markerAppearance = false
    @State private var photoRequest: Workspace.Request?
    @State private var photoTransfer: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var canvasEngine: CanvasEngine
    @State private var anchorHeight: CGFloat = 78
    @State private var supplementHeight: CGFloat = 0
    @ScaledMetric(relativeTo: .body) private var supplementaryActionHeight: CGFloat = 56
    init(workspace: Workspace) {
        self.workspace = workspace
        _canvasEngine = State(initialValue: CanvasEngine(workspace))
    }
    private var largeControls: Bool { dynamicTypeSize.isAccessibilitySize }
    var body: some View {
        let epoch = workspace.lifecycleEpoch
        let filesRequest = workspace.filesRequest
        let jsonRequest = workspace.jsonRequest
        let clearTarget = workspace.clearTarget
        workspaceSurface
        .preferredColorScheme(.light)
        .onChange(of:workspace.exportShown){_,shown in if shown{workspace.invalidateBirdDetection(message:"Exports include committed markers only.")}}
        .photosPicker(isPresented: $showPhotos, selection: $photoItem, matching: .images, preferredItemEncoding: .current)
        .task { await workspace.startup() }
        .onChange(of: photoItem) { _, item in
            guard let item, let request = photoRequest, workspace.isLive(request.epoch) else { return }
            let transfer = UUID(); photoTransfer = transfer
            Task {
                await workspace.receivePhotoTransfer(request, isCurrent: { photoRequest == request && photoTransfer == transfer }) {
                    try await item.loadTransferable(type: PickedPhoto.self)
                }
                if workspace.isLive(request.epoch), photoRequest == request, photoTransfer == transfer { photoItem = nil; photoTransfer = nil }
            }
        }
        .onChange(of: workspace.lifecycleEpoch) { _, _ in showPhotos = false; photoRequest = nil; photoTransfer = nil; photoItem = nil }
        .fileImporter(isPresented: $workspace.openFiles, allowedContentTypes: [.jpeg, .png, .heic, .heif], allowsMultipleSelection: false) { result in
            guard let request = filesRequest else { return }
            Task { await workspace.receiveFileResult(result, request: request, json: false) }
        }
        .fileImporter(isPresented: $workspace.openJSON, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard let request = jsonRequest else { return }
            Task { await workspace.receiveFileResult(result, request: request, json: true) }
        }
        .alert("Clear workspace?", isPresented: Binding(get: { workspace.clearTarget != nil }, set: { if !$0 { workspace.clearTarget = nil } })) {
            Button("Cancel", role: .cancel) { workspace.clearTarget = nil }.keyboardShortcut(.defaultAction)
            Button("Clear workspace", role: .destructive) { if let clearTarget { Task { await workspace.confirmClear(clearTarget) } } }
        } message: {
            if let clearTarget {
                Text("\(clearTarget.filename) · \(clearTarget.total) markers\n\nRemove this photo, count and local recovery copy from Flock Dotter. This can’t be undone.\n\nYour originals in Photos or Files and existing exports stay untouched.\n\nTo keep an editable count, cancel and export JSON. Keep it with the unchanged original photo.")
            }
        }
        .alert("Flock Dotter", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .confirmationDialog("Replace this count?", isPresented: $workspace.showReplacement, titleVisibility: .visible) {
            Button("Export JSON…") { if workspace.isLive(epoch) { workspace.showExport(tab: 1) } }
            Button("Replace Count", role: .destructive) { Task { await workspace.replace(requestEpoch: epoch) } }
            Button("Cancel", role: .cancel) { if workspace.isLive(epoch) { workspace.cancelReplacement() } }
        } message: { Text("You have \(workspace.markedBirds) with edits that haven’t been exported as JSON. Recovery keeps only the current workspace. To retain this count for later editing, export its JSON and keep the unchanged original photo.") }
        .sheet(isPresented: $workspace.exportShown, onDismiss: { workspace.retireExport(); if workspace.isLive(epoch), workspace.pending != nil { workspace.showReplacement = true } }) {
            if let capture = workspace.exportCapture { ExportView(workspace: workspace, capture: capture).id(capture.id) }
        }
        .sheet(isPresented: $workspace.showPairing) { pairingView(epoch: epoch) }
        .sheet(isPresented: $markerAppearance) { MarkerAppearanceView(workspace: workspace) }
        .sheet(isPresented: $help) { WorkspaceHelp(enabled: workspace.birdPrototypeEnabled) { help = false } }
    }
    @ViewBuilder private var workspaceSurface: some View {
        #if os(iOS)
        NavigationStack {
            GeometryReader { geometry in
                let regions = activeRegions(in: geometry)
                ZStack(alignment: .topLeading) {
                    Design.canvas
                    adaptiveCanvas(size: regions.canvas.size, folded: regions.controls != nil)
                        .frame(width: regions.canvas.width, height: regions.canvas.height)
                        .position(x: regions.canvas.midX, y: regions.canvas.midY)
                    if let controls = regions.controls {
                        VStack(alignment: .leading, spacing: 12) {
                            countModeAnchor(width: controls.width - 24)
                            supplementaryControls
                            Spacer(minLength: 0)
                        }.padding(12)
                            .frame(width: controls.width, height: controls.height, alignment: .topLeading)
                            .background(Design.surface)
                            .position(x: controls.midX, y: controls.midY)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
            .toolbar { workspaceToolbar }
            .toolbarTitleDisplayMode(.inline)
            .background(Design.canvas)
        }.foregroundStyle(Design.ink).tint(Design.accent).font(Design.font())
        #else
        legacyWorkspace
        #endif
    }

    #if os(iOS)
    private func activeRegions(in geometry: GeometryProxy) -> WorkspaceRegions {
        let bounds = CGRect(origin: .zero, size: geometry.size)
        if #available(iOS 27.1, *) {
            return WorkspaceRegions(bounds: bounds,
                divisions: geometry.reservedRegions(kind: .division).map(\.frame),
                occlusions: geometry.reservedRegions(kind: .occlusion).map(\.frame))
        }
        return WorkspaceRegions(bounds: bounds, divisions: [], occlusions: [])
    }
    private func adaptiveCanvas(size: CGSize, folded: Bool) -> some View {
        let minimumCanvas: CGFloat = largeControls ? 110 : 160
        let hasSupplement = workspace.renumberProgress || workspace.renumberFailure || workspace.selectedLabel != nil || workspace.birdReview != nil || workspace.birdKey != nil || !workspace.birdMessage.isEmpty || workspace.clearFailed || workspace.recoveryStale
        let anchorWidth = max(0, size.width - 24)
        // Each float has 12pt safe-edge clearance and a 12pt gap to the
        // unobstructed canvas. Use this same budget for sizing and fallback.
        let topClearance = anchorHeight + 24
        let bottomClearance: CGFloat = 24
        let budget = max(0, size.height - topClearance - minimumCanvas - bottomClearance)
        // A bounded scroller must be able to display a complete primary action
        // row (56pt review decisions / >=44pt selection targets), plus its
        // vertical padding. Scale that viewport with text rather than squeezing
        // controls into the few pixels left after allocating the canvas.
        let actionViewport = max(44, supplementaryActionHeight) + 16
        let requiredSupplement = hasSupplement ? min(supplementHeight > 0 ? supplementHeight : actionViewport, actionViewport) : 0
        let extreme = !folded && size.height < topClearance + minimumCanvas + bottomClearance + requiredSupplement
        return Group {
            if extreme {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        countModeAnchor(width: anchorWidth).padding(.horizontal, 12)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: AnchorHeightKey.self, value: proxy.size.height)
                            })
                        NativeCanvas(workspace: workspace, appearance: workspace.appearance, connections: workspace.connections, retainedEngine: canvasEngine)
                            .frame(height: minimumCanvas).accessibilityIdentifier("countingCanvas")
                        if workspace.candidate == nil { emptyState(compact: true) }
                        if hasSupplement { supplementaryContents }
                    }.padding(.vertical, 12)
                }.accessibilityIdentifier("workspaceContents").clipped()
            } else {
            ZStack(alignment: .topLeading) {
            NativeCanvas(workspace: workspace, appearance: workspace.appearance, connections: workspace.connections, retainedEngine: canvasEngine,
                         workingInsets: folded ? .init() : EdgeInsets(top: topClearance, leading: 12,
                              bottom: min(supplementHeight, budget) + bottomClearance, trailing: 12))
                .accessibilityIdentifier("countingCanvas")
                .accessibilityAction(named: Text("Remove selected marker")) { nativeAction("Remove") { workspace.remove() } }
                .accessibilityAction(named: Text("Deselect marker")) { workspace.deselect() }
            if workspace.candidate == nil {
                ScrollView {
                    emptyState(compact: size.height < anchorHeight + 340)
                        .frame(maxWidth: .infinity)
                }.padding(.top, folded ? 0 : min(anchorHeight + 24, size.height / 2))
                    .accessibilityIdentifier("emptyWorkspaceContents")
            }
            if !folded {
                    countModeAnchor(width: anchorWidth).padding(12)
                        .background(GeometryReader { proxy in
                            Color.clear.preference(key: AnchorHeightKey.self, value: proxy.size.height - 24)
                        })
                    if hasSupplement {
                        supplementaryControls.frame(height: min(supplementHeight, budget))
                            .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    }
            }
            if workspace.clearing || workspace.busy {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(workspace.clearing ? "Clearing workspace…" : workspace.committing ? "Saving count…" : workspace.recovering ? "Recovering current count…" : "Opening photo…")
                    if !workspace.committing && !workspace.clearing { Button("Cancel") { workspace.cancelOpening() }.frame(minHeight: 44) }
                }.padding(24).background(Design.surface, in: RoundedRectangle(cornerRadius: 20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            }
            }
        }.frame(width: size.width, height: size.height).clipped()
            .buttonStyle(InstrumentButtonStyle())
            .onPreferenceChange(AnchorHeightKey.self) { if $0 > 0 { anchorHeight = $0 } }
            .onPreferenceChange(SupplementHeightKey.self) { supplementHeight = $0 }
            .onChange(of: hasSupplement) { _, value in if !value { supplementHeight = 0 } }
    }
    private func countModeAnchor(width: CGFloat) -> some View {
        InstrumentGlassContainer {
            WorkspaceAnchorLayout(availableWidth: width) {
                Group {
                    if largeControls {
                        VStack(alignment: .leading, spacing: 0) {
                            totalNumber(compact: true)
                            Text(workspace.markedBirdsNoun).font(Design.font(13))
                        }
                    } else {
                        HStack(spacing: 8) {
                            totalNumber(compact: true)
                            Text(workspace.total == 1 ? "bird\nmarked" : "birds\nmarked").font(Design.font(13)).fixedSize()
                        }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Design.surface, in: Capsule())
                    .overlay(Capsule().stroke(Design.line, lineWidth: 1))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(workspace.markedBirds)
                    .accessibilityValue(workspace.candidate?.identity.originalFilename ?? "One photo. One count.")
                    .accessibilityIdentifier("countTotal")
                modePicker.padding(4).instrumentChrome()
                if sourceDetailFits(width: width), let source = workspace.candidate?.identity {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(source.originalFilename).font(Design.font(12, bold: true)).lineLimit(2)
                        Text("\(source.pixelWidth) × \(source.pixelHeight)").font(Design.font(11))
                    }.foregroundStyle(Design.secondary).padding(.horizontal, 14).padding(.vertical, 8)
                        .frame(maxWidth: 220, alignment: .leading).background(Design.surface, in: Capsule())
                        .accessibilityHidden(true)
                }
            }
        }.frame(maxWidth: width, alignment: .leading)
    }
    private func sourceDetailFits(width: CGFloat) -> Bool {
        guard !largeControls else { return false }
        let unitFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "IBMPlexSans", size: 13) ?? .systemFont(ofSize: 13))
        let numberFont = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: UIFont(name: "IBMPlexMono-SemiBold", size: 42) ?? .monospacedSystemFont(ofSize: 42, weight: .semibold))
        let modeFont = UIFontMetrics(forTextStyle: .body).scaledFont(for: UIFont(name: "IBMPlexSans-SemiBold", size: 14) ?? .systemFont(ofSize: 14))
        let totalWidth = (workspace.total.formatted() as NSString).size(withAttributes: [.font: numberFont]).width + ("marked" as NSString).size(withAttributes: [.font: unitFont]).width + 36
        let modeWidth = max(140, ("Count" as NSString).size(withAttributes: [.font: modeFont]).width * 2 + 40) + 8
        return width >= totalWidth + modeWidth + 220 + 16
    }
    private var supplementaryControls: some View {
        ScrollView {
            supplementaryContents.background(GeometryReader { proxy in
                Color.clear.preference(key: SupplementHeightKey.self, value: proxy.size.height)
            })
        }.scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("workspaceSupplementaryControls")
            .background(Design.surface, in: RoundedRectangle(cornerRadius: 20))
            .clipShape(RoundedRectangle(cornerRadius: 20))
    }
    private var supplementaryContents: some View {
        VStack(alignment: .leading, spacing: 8) {
            renumberStatus
            selectionControls
            if !workspace.clearing && (workspace.birdReview != nil || workspace.birdKey != nil || !workspace.birdMessage.isEmpty) {
                BirdReviewControls(workspace: workspace)
            }
            if workspace.clearFailed {
                VStack(alignment: .leading, spacing: 8) { clearFailureText; clearFailureActions }
                    .padding(12).foregroundStyle(Design.warning).background(Design.warningSurface)
            } else if workspace.recoveryStale {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recovery isn’t up to date. Your count is still here.")
                    Button("Retry") { workspace.scheduleSave() }.frame(minHeight: 44)
                    Button("Export JSON") { workspace.showExport(tab: 1) }.frame(minHeight: 44)
                }.padding(12).foregroundStyle(Design.warning).background(Design.warningSurface)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ToolbarContentBuilder private var workspaceToolbar: some ToolbarContent {
        if #available(iOS 27, *) {
            ToolbarItem(placement: .topBarLeading) { openMenu }.visibilityPriority(.high)
            ToolbarItem(placement: .primaryAction) { nativeExport }.visibilityPriority(.high)
            ToolbarItem(placement: .bottomBar) { undoButton }.visibilityPriority(.high)
            ToolbarItem(placement: .bottomBar) { redoButton }.visibilityPriority(.low)
            ToolbarItem(placement: .bottomBar) { zoomOutButton }
            ToolbarItem(placement: .bottomBar) { zoomInButton }
            ToolbarItem(placement: .bottomBar) { fitButton }.visibilityPriority(.high)
            ToolbarOverflowMenu { secondaryActions }
        } else {
            ToolbarItem(placement: .topBarLeading) { openMenu }
            ToolbarItem(placement: .primaryAction) { nativeExport }
            ToolbarItemGroup(placement: .bottomBar) {
                undoButton
                fitButton
                Menu { redoButton; zoomOutButton; zoomInButton; secondaryActions } label: { Label("More actions", systemImage: "ellipsis") }
            }
        }
    }
    private var navigationDisabled: Bool { workspace.candidate == nil || workspace.busy || workspace.clearing || workspace.exportShown }
    private var nativeExport: some View {
        Button { workspace.showExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }
            .tint(workspace.birdReview == nil ? Design.accent : Design.ink)
            .disabled(navigationDisabled)
    }
    private var undoButton: some View {
        Button { nativeAction("Undo") { workspace.undo() } } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
            .keyboardShortcut("z", modifiers: .command).disabled(!workspace.history.canUndo || navigationDisabled)
    }
    private var redoButton: some View {
        Button { nativeAction("Redo") { workspace.redo() } } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
            .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!workspace.history.canRedo || navigationDisabled)
    }
    private var zoomOutButton: some View {
        Button { workspace.zoomCommand -= 1 } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
            .keyboardShortcut("-", modifiers: .command).disabled(navigationDisabled)
    }
    private var zoomInButton: some View {
        Button { workspace.zoomCommand += 1 } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
            .keyboardShortcut("+", modifiers: .command).disabled(navigationDisabled)
    }
    private var fitButton: some View {
        Button { workspace.fitCommand += 1 } label: { Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right") }
            .keyboardShortcut("0", modifiers: .command).disabled(navigationDisabled)
    }
    @ViewBuilder private var secondaryActions: some View {
        connectionsToggle
        Button { markerAppearance = true } label: {
            Label("Marker appearance · \(workspace.appearance.style.name) · \(workspace.appearance.color.name)", systemImage: "circle.inset.filled")
        }.accessibilityIdentifier("markerAppearance")
            .disabled(workspace.clearing || workspace.committing || workspace.busy || workspace.exportShown)
        sortMenu
        if workspace.birdPrototypeEnabled {
            Button { workspace.startBirdDetection() } label: { Label("Detect birds", systemImage: "bird") }
                .disabled(!workspace.canDetectBirds).accessibilityIdentifier("detectBirds")
            Text("Local prototype · Suggestions need review")
        }
        Button { help = true } label: { Label("Help", systemImage: "questionmark.circle") }
    }
    #endif
    private var legacyWorkspace: some View {
        GeometryReader { geometry in
            if workspace.candidate == nil, !workspace.busy, !workspace.clearing,
               !workspace.recoveryStale, !workspace.clearFailed,
               largeControls || geometry.size.height < 500 {
                constrainedEmptyWorkspace(width: geometry.size.width, height: geometry.size.height)
            } else {
            VStack(spacing: 0) {
                if largeControls || geometry.size.height < 500 {
                    InstrumentGlassContainer {
                    ScrollView {
                        VStack(spacing: 0) {
                            sourceHeader(compact: true)
                            toolArea(width: geometry.size.width)
                        }
                    }.accessibilityIdentifier("workspaceTopControls")
                    }.frame(maxHeight: geometry.size.height * 0.45).clipped()
                } else {
                    InstrumentGlassContainer {
                        VStack(spacing: 0) {
                            sourceHeader(compact: geometry.size.width < 650)
                            toolArea(width: geometry.size.width)
                        }
                    }
                }
                if workspace.renumberProgress || workspace.renumberFailure {
                    ScrollView { renumberStatus }.frame(maxHeight: geometry.size.height * 0.22)
                }
                if workspace.clearFailed {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) { clearFailureText; clearFailureActions }
                        VStack(alignment: .leading, spacing: 8) { clearFailureText; clearFailureActions }
                    }.padding(12).foregroundStyle(Design.warning).background(Design.warningSurface)
                } else if workspace.recoveryStale {
                    HStack {
                        Text("Recovery isn’t up to date. Your count is still here.").font(Design.font(13))
                        Button("Retry") { workspace.scheduleSave() }
                        Button("Export JSON") { workspace.showExport(tab: 1) }
                    }.padding(12).foregroundStyle(Design.warning).background(Design.warningSurface)
                }
                ZStack {
                    NativeCanvas(workspace: workspace, appearance: workspace.appearance, connections: workspace.connections).accessibilityIdentifier("countingCanvas")
                        .accessibilityAction(named: Text("Remove selected marker")) { nativeAction("Remove") { workspace.remove() } }
                        .accessibilityAction(named: Text("Deselect marker")) { workspace.deselect() }
                    if workspace.candidate == nil {
                        // Keep the empty message's intrinsic text height out of the
                        // canvas proposal. At large text sizes it scrolls inside the
                        // remaining canvas rather than pushing both tool regions away.
                        GeometryReader { emptyGeometry in
                            ScrollView {
                                emptyState(compact: geometry.size.height < 500).frame(maxWidth: .infinity)
                                    .frame(minHeight: emptyGeometry.size.height)
                            }.accessibilityIdentifier("emptyWorkspaceContents")
                                .frame(width: emptyGeometry.size.width, height: emptyGeometry.size.height)
                                .clipped().contentShape(Rectangle())
                        }
                    }
                    if workspace.clearing || workspace.busy {
                        VStack(spacing: 12) {
                            ProgressView(); Text(workspace.clearing ? "Clearing workspace…" : workspace.committing ? "Saving count…" : workspace.recovering ? "Recovering current count…" : "Opening photo…").font(Design.font())
                            if workspace.clearing { Text("Removing this photo and count from recovery.").font(Design.font(13)) }
                            if !workspace.committing && !workspace.clearing { Button("Cancel") { workspace.cancelOpening() }.frame(minHeight: 44) }
                        }.padding(24).background(Design.surface, in: RoundedRectangle(cornerRadius: 12)).shadow(color: Design.navy.opacity(0.13), radius: 16)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                if !workspace.clearing && (workspace.birdReview != nil || workspace.birdKey != nil || !workspace.birdMessage.isEmpty) {
                    ScrollView {BirdReviewControls(workspace:workspace)}.frame(maxHeight:geometry.size.height * (largeControls ? 0.45:0.38))
                }
                if largeControls {
                    InstrumentGlassContainer {
                    ScrollView {
                        VStack(spacing: 0) { selectionControls; footer(width: geometry.size.width) }
                    }.accessibilityIdentifier("workspaceBottomControls")
                    }.frame(maxHeight: geometry.size.height * 0.30).clipped()
                } else {
                    selectionControls
                    InstrumentGlassContainer { footer(width: geometry.size.width) }
                }
            }
            .background(Design.surface).foregroundStyle(Design.ink).tint(Design.accent)
            .font(Design.font()).buttonStyle(InstrumentButtonStyle())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: workspace.selectedLabel != nil)
            // Confine scrolling chrome and its glass to the safe-area viewport.
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
        }
    }
    @ViewBuilder private var selectionControls: some View {
        if let label = workspace.selectedLabel {
            if largeControls {
                expandedSelection(label: label).padding(16).background(Design.tint)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        Text("Marker \(label)").font(Design.font(14, bold: true)).fixedSize()
                        selectionInstruction.fixedSize()
                        Spacer(minLength: 0)
                        selectionActions
                    }
                    expandedSelection(label: label)
                }.padding(.horizontal, 16).padding(.vertical, 8).background(Design.tint)
            }
        }
    }
    private var selectionInstruction: some View {
        Text(workspace.mode == .edit ? "Drag to reposition" : "Already counted · Switch to Edit to move")
            .font(Design.font(12)).foregroundStyle(Design.secondary)
    }
    private func expandedSelection(label: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Marker \(label)").font(Design.font(14, bold: true))
            selectionInstruction
            HStack { selectionActions }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var selectionActions: some View {
        Group {
        if workspace.mode == .edit {
            Button(role: .destructive) { nativeAction("Remove") { workspace.remove() } } label: {
                Label("Remove", systemImage: "trash").fixedSize(horizontal: true, vertical: false)
            }.fixedSize(horizontal: true, vertical: false).frame(minHeight: 44)
        }
        Spacer(minLength: 0)
        Button { workspace.deselect() } label: { Image(systemName: "xmark") }
            .accessibilityLabel("Deselect marker").frame(minWidth: 44, minHeight: 44)
        }.disabled(workspace.clearing)
    }
    private func nativeAction(_ name: String, _ perform: () -> Void) {
        #if DEBUG
        NativeQARecorder.shared.begin(name)
        #endif
        perform()
    }
    private func sourceHeader(compact: Bool) -> some View {
        Group {
            if largeControls {
                VStack(alignment: .leading, spacing: 12) {
                    sourceTitle(compact: compact)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 16) { sourceActions }
                        VStack(alignment: .leading, spacing: 8) { sourceActions }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 16) { sourceTitle(compact: compact); Spacer(minLength: 0); sourceActions }
            }
        }.padding(.horizontal, 16).padding(.vertical, 12).background(Design.surface)
    }
    private func sourceTitle(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact { Text("Flock Dotter").font(Design.font(20, bold: true)) }
            Group {
                if largeControls || compact {
                    VStack(alignment: .leading, spacing: 0) { totalNumber(compact: compact); Text(workspace.markedBirdsNoun).font(Design.font(13)) }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) { totalNumber(compact: compact); Text(workspace.markedBirdsNoun).font(Design.font(13)) }
                }
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(workspace.markedBirds).accessibilityIdentifier("countTotal")
            Text(workspace.candidate?.identity.originalFilename ?? "One photo. One count.").font(Design.font(12)).foregroundStyle(Design.secondary).lineLimit(largeControls ? nil : 2)
        }
    }
    private func totalNumber(compact: Bool) -> some View {
        NativeTotalLabel(value: workspace.total, revision: workspace.snapshot?.revision ?? 0, compact: compact)
    }
    @ViewBuilder private var sourceActions: some View {
        openMenu
        Button { workspace.showExport() } label: { Label("Export", systemImage: "square.and.arrow.up").fixedSize() }.buttonStyle(InstrumentButtonStyle(primary: workspace.birdReview == nil)).frame(minHeight: 44).disabled(workspace.candidate == nil || workspace.busy || workspace.clearing || workspace.exportShown)
    }
    private var openMenu: some View { openMenu(title: "Open") }
    private func openMenu(title: String) -> some View {
        Menu {
            Button("Choose from Photos…", systemImage: "photo.on.rectangle") {
                guard let request = workspace.newRequest() else { return }
                photoRequest = request; showPhotos = true
            }.disabled(!workspace.canOpen)
            Button("Choose from Files…", systemImage: "folder") { workspace.openPhotoFiles() }.disabled(!workspace.canOpen)
            Button("Reopen Count…", systemImage: "doc.badge.arrow.up") { workspace.openCountFile() }.disabled(!workspace.canOpen)
            Divider()
            Button(role: .destructive) { workspace.requestClear() } label: { Label("Clear workspace…", systemImage: "trash") }.disabled(!workspace.canClear)
        } label: { Label(title, systemImage: "folder").fixedSize() }.frame(minHeight: 44).disabled(workspace.clearing || workspace.committing)
    }
    private func toolArea(width: CGFloat) -> some View {
        Group {
            if width >= 1000 && !largeControls {
                HStack(spacing: 16) { controls(width: width); birdEntry; Spacer(minLength: 0) }
            } else {
                VStack(alignment: .leading, spacing: 8) { controls(width: width); birdEntry }
            }
        }.padding(.horizontal, 16).padding(.bottom, 12)
    }
    private func controls(width: CGFloat) -> some View {
        Group {
            if largeControls {
                VStack(alignment: .leading, spacing: 8) { modePicker; historyButtons; sortMenu }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if width < 390 {
                VStack(spacing: 4) { modePicker; HStack { historyButtons; sortMenu } }
            } else {
                HStack(spacing: 4) { modePicker; historyButtons; sortMenu }
            }
        }.padding(4).instrumentChrome()
        .disabled(workspace.candidate == nil || workspace.busy || workspace.clearing || workspace.exportShown)
    }
    private var modePicker: some View {
        #if os(iOS)
        NativeModePicker(workspace: workspace).fixedSize().accessibilityLabel("Count or Edit mode")
        #else
        NativeModePicker(workspace: workspace).frame(width: 176, height: 44).accessibilityLabel("Count or Edit mode")
        #endif
    }
    @ViewBuilder private var birdEntry:some View {
        if workspace.birdPrototypeEnabled {
            HStack(spacing:12) {
                Button("Detect birds"){workspace.startBirdDetection()}.frame(minHeight:44).disabled(!workspace.canDetectBirds).accessibilityIdentifier("detectBirds")
                Text("Local prototype · Suggestions need review").font(Design.font(11)).foregroundStyle(Design.secondary)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }
    }
    private var historyButtons: some View {
        HStack(spacing: 4) {
            Button { nativeAction("Undo") { workspace.undo() } } label: { Image(systemName: "arrow.uturn.backward") }.accessibilityLabel("Undo").keyboardShortcut("z", modifiers: .command).disabled(!workspace.history.canUndo).frame(minWidth: 44, minHeight: 44)
            Button { nativeAction("Redo") { workspace.redo() } } label: { Image(systemName: "arrow.uturn.forward") }.accessibilityLabel("Redo").keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!workspace.history.canRedo).frame(minWidth: 44, minHeight: 44)
        }
    }
    private var sortMenu: some View {
        Menu {
            Button("Left to Right") { nativeAction("Renumber Left to Right") { workspace.renumber(.leftToRight) } }
            Button("Top to Bottom") { nativeAction("Renumber Top to Bottom") { workspace.renumber(.topToBottom) } }
            Button("Nearest Neighbor") { nativeAction("Nearest Neighbor") { workspace.renumber(.nearestNeighbor) } }
                .accessibilityHint("Renumbers nearby committed dots, starting at the topmost dot. Keeps positions and total. Turns connections on. You can undo the order.")
            Text("Changes labels only. You can undo this.")
        } label: { Label("Renumber", systemImage: "list.number").fixedSize() }.frame(minHeight: 44).disabled(!workspace.canRenumber)
    }
    /// Empty work has no photo navigation to reserve. One scroll owner avoids
    /// independently scrolled controls retaining overlapping native hit regions.
    private func constrainedEmptyWorkspace(width: CGFloat, height: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                InstrumentGlassContainer {
                    VStack(spacing: 0) {
                        sourceHeader(compact: true)
                        toolArea(width: width)
                    }
                }
                emptyState(compact: height < 500)
                    .frame(maxWidth: .infinity).background(Design.canvas)
                InstrumentGlassContainer { footer(width: width) }
            }
        }.accessibilityIdentifier("emptyWorkspaceContents")
            .frame(width: width, height: height).clipped().contentShape(Rectangle())
            .background(Design.surface).foregroundStyle(Design.ink).tint(Design.accent)
            .font(Design.font()).buttonStyle(InstrumentButtonStyle())
    }

    private func footer(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            Divider().overlay(Design.line)
            Group {
                if largeControls || width < 900 {
                    VStack(alignment: .leading, spacing: 8) { navigationTools; appearanceAndHelp(width: width) }
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: 12) { navigationTools; Spacer(minLength: 0); appearanceAndHelp(width: width) }
                }
            }.padding(.vertical, 8)
            #if os(macOS)
            Text(workspace.mode == .count ? "Click to count · Drag to pan · Pinch to zoom" : "Drag a marker to move · Space-drag to pan").font(Design.font(11)).foregroundStyle(Design.secondary)
            #else
            Text(workspace.mode == .count ? "Tap to count · Drag to pan · Pinch to zoom" : "Drag a marker to move · Pinch to zoom").font(Design.font(11)).foregroundStyle(Design.secondary)
            #endif
            Text(workspace.clearing ? "Clearing workspace…" : workspace.recoveryStale ? "Recovery needs attention" : workspace.recoveryMessage.isEmpty ? "JPEG, PNG or HEIC · One photo at a time" : workspace.recoveryMessage).font(Design.font(11)).foregroundStyle(Design.secondary).padding(.bottom, 8).accessibilityAddTraits(.updatesFrequently)
        }.padding(.horizontal, 16).background(Design.surface)
    }
    private var navigationTools: some View {
                HStack(spacing: 4) {
                Button { if !workspace.clearing { workspace.zoomCommand -= 1 } } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom Out").keyboardShortcut("-", modifiers: .command).frame(minWidth: 44, minHeight: 44)
                Button { if !workspace.clearing { workspace.zoomCommand += 1 } } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom In").keyboardShortcut("+", modifiers: .command).frame(minWidth: 44, minHeight: 44)
                Button("Fit") { if !workspace.clearing { workspace.fitCommand += 1 } }.fixedSize().keyboardShortcut("0", modifiers: .command).frame(minWidth: 44, minHeight: 44)
                }.disabled(workspace.candidate == nil || workspace.busy || workspace.clearing || workspace.exportShown)
                .padding(4).instrumentChrome()
    }
    private func appearanceAndHelp(width: CGFloat) -> some View {
        Group {
            if largeControls || width < 650 { VStack(alignment: .leading, spacing: 4) { connectionsToggle; appearanceButton; helpButton } }
            else { HStack(spacing: 8) { connectionsToggle; appearanceButton; helpButton } }
        }
    }
    private var connectionsToggle: some View {
        Toggle("Show connections", isOn: Binding(get: { workspace.connections.isVisible }, set: { workspace.setConnectionsVisible($0) }))
            .accessibilityIdentifier("showConnections")
            .accessibilityHint("Shows lines between consecutive labels. Remembered on this installation. Does not change your count.")
            .frame(minHeight: 44)
    }
    @ViewBuilder private var renumberStatus: some View {
        if workspace.renumberProgress {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { ProgressView().accessibilityHidden(true); Text("Renumbering…").font(Design.font(14, bold: true)) }
                    .accessibilityElement(children: .ignore).accessibilityLabel("Renumbering. Cancel available.")
                    .accessibilityAddTraits(.updatesFrequently)
                Text("Your count stays in place until this finishes.").font(Design.font(13))
                Button("Cancel") { workspace.cancelRenumber() }.frame(minHeight: 44)
                    .accessibilityLabel("Cancel renumbering").accessibilityHint("Keeps the current marker order.")
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Design.surface)
        } else if workspace.renumberFailure {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn’t finish renumbering.").font(Design.font(14, bold: true))
                Text("Your count is unchanged. Try again.").font(Design.font(13))
                HStack {
                    Button("Retry") { workspace.renumber(.nearestNeighbor) }.frame(minHeight: 44).disabled(!workspace.canRenumber)
                    Button("Dismiss") { workspace.renumberFailure = false }.frame(minHeight: 44)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).foregroundStyle(Design.warning).background(Design.warningSurface)
        }
    }
    private var appearanceButton: some View {
        Button { markerAppearance = true } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(cgColor: workspace.appearance.color.fill)).frame(width: 14, height: 14)
                    .overlay(Circle().stroke(Design.navy, lineWidth: 1))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Marker appearance")
                    Text("\(workspace.appearance.style.name) · \(workspace.appearance.color.name)").font(Design.font(12)).foregroundStyle(Design.secondary)
                }
            }
        }.accessibilityLabel("Marker appearance, \(workspace.appearance.style.name), \(workspace.appearance.color.name)")
            .accessibilityIdentifier("markerAppearance").frame(minHeight: 44)
            .disabled(workspace.clearing || workspace.committing || workspace.busy || workspace.exportShown)
    }
    private var helpButton: some View { Button { help = true } label: { Label("Help", systemImage: "questionmark.circle").fixedSize() }.accessibilityLabel("Help").frame(minWidth: 44, minHeight: 44) }
    private func emptyState(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !compact {
                Image(systemName: "photo").font(.system(size: 36, weight: .light)).foregroundStyle(Design.secondary)
                Text("A photo. A flock.\nA count you can follow.").font(Design.font(27, bold: true)).tracking(-0.5)
                Text("Open a bird photo, then tap or click each bird to mark your count.").font(Design.font(15)).fixedSize(horizontal: false, vertical: true)
            }
            openMenu(title: "Open Photo").buttonStyle(InstrumentButtonStyle(primary: true))
            Button("Reopen Count") { workspace.openCountFile() }.frame(minHeight: 44)
            if compact {
                Text("Open a bird photo, then tap or click each bird to mark your count.").font(Design.font(15)).fixedSize(horizontal: false, vertical: true)
            }
            Text("JPEG, PNG or HEIC · One photo at a time").font(Design.font(12)).foregroundStyle(Design.secondary)
        }.frame(maxWidth: largeControls ? .infinity : 390, alignment: .leading).padding(24)
    }
    private func pairingView(epoch: UUID) -> some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("The marker file needs the exact photo used for the count.").font(Design.font(15))
                if let doc = workspace.pairing {
                    Text(doc.image.originalFilename).font(Design.font(17, bold: true))
                    Text("\(doc.image.pixelWidth) × \(doc.image.pixelHeight) pixels · \(doc.markers.count) markers").font(Design.font(13))
                    if let candidate = workspace.candidate, doc.image.matches(candidate.identity) { Button("Use This Photo") { Task { await workspace.useCurrentPhoto(requestEpoch: epoch) } }.buttonStyle(InstrumentButtonStyle(primary: true)).frame(minHeight: 44) }
                }
                Button("Choose Original Photo…") { if workspace.isLive(epoch) { workspace.showPairing = false; workspace.openPhotoFiles(pairingOriginal: true) } }.frame(minHeight: 44)
                Text("Renaming or moving the original is fine. Editing it, re-saving it, or changing its metadata prevents a match.").font(Design.font(13)).foregroundStyle(Design.secondary)
                Spacer()
            }.padding(24)
            }.background(Design.surface).navigationTitle("Locate the original photo").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if workspace.isLive(epoch) { workspace.pairing = nil; workspace.showPairing = false } } } }
        }.font(Design.font()).foregroundStyle(Design.ink).tint(Design.accent).buttonStyle(InstrumentButtonStyle())
        .instrumentSheet(width: 480, minimumHeight: 340).preferredColorScheme(.light)
    }
    private var clearFailureText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Couldn’t finish clearing").font(Design.font(14, bold: true))
            Text("Your photo and count are still here. Recovery couldn’t be confirmed. Try clearing again, or export JSON to keep this count.").font(Design.font(13)).fixedSize(horizontal: false, vertical: true)
        }
    }
    private var clearFailureActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack { clearRetry; clearExport }
            VStack(alignment: .leading) { clearRetry; clearExport }
        }.disabled(workspace.clearing)
    }
    private var clearRetry: some View { Button("Try again…") { workspace.requestClear() }.frame(minHeight: 44) }
    private var clearExport: some View { Button("Export JSON") { workspace.showExport(tab: 1) }.frame(minHeight: 44) }
}

struct WorkspaceHelp: View {
    let enabled: Bool
    let done: () -> Void
    // Static text only. Reading attribution must never initialize the detector.
    private static let notices: String? = {
        #if DEBUG || OWNER_BETA || PUBLIC_STORE
        guard let url = Bundle.main.url(forResource: "Third-party-notices", withExtension: "txt", subdirectory: "BirdPrototype") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
        #else
        return nil
        #endif
    }()
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Privacy, source and licenses").font(Design.font(17, bold: true)).accessibilityAddTraits(.isHeader)
                        NavigationLink("Privacy policy") { BundledHelpDocument(title: "Privacy policy", resource: "privacy", extension: "md") }.frame(minHeight: 44)
                        NavigationLink("Support") { BundledHelpDocument(title: "Support", resource: "support", extension: "md") }.frame(minHeight: 44)
                        Link("Source code", destination: URL(string: "https://github.com/dtgibson/flockdotter")!).frame(minHeight: 44)
                        NavigationLink("GNU AGPL version 3") { BundledHelpDocument(title: "GNU AGPL version 3", resource: "LICENSE", extension: nil) }.frame(minHeight: 44)
                        NavigationLink("Copyright and third-party licenses") { BundledHelpDocument(title: "Copyright and licenses", resource: "THIRD_PARTY_NOTICES", extension: "md") }.frame(minHeight: 44)
                        NavigationLink("IBM Plex Sans license") { BundledHelpDocument(title: "IBM Plex Sans license", resource: "OFL-IBM-Plex-Sans", extension: "txt") }.frame(minHeight: 44)
                        NavigationLink("IBM Plex Mono license") { BundledHelpDocument(title: "IBM Plex Mono license", resource: "OFL-IBM-Plex-Mono", extension: "txt") }.frame(minHeight: 44)
                        Link("Privacy policy online", destination: URL(string: "https://github.com/dtgibson/flockdotter/blob/main/docs/public/privacy.md")!).frame(minHeight: 44)
                    }
                    if enabled {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Bird detection · Experimental").font(Design.font(17, bold: true)).accessibilityAddTraits(.isHeader)
                            Text("A first pass you review.\nYou choose what joins the count.").font(Design.font(20, bold: true))
                            Text("Detect birds suggests locations in your photo. Your count stays unchanged until you review and add a batch.")
                            Text("It can miss birds or suggest false or duplicate locations. No suggestions doesn’t mean there are no birds.")
                            Text("Everything runs on this device. No photo upload, internet connection, account or API key is needed.").padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Design.tint)
                            Text("This prototype supports small photos. Ordinary full-resolution phone photos are generally refused. If a scan can’t finish within its work, time or memory limits, it stops without adding any markers. You can always count manually.")
                            DisclosureGroup {
                                paragraphs([
                                    "Suggestions start pending. Accept birds, reject false suggestions, or skip the remaining suggestions. Skipped suggestions aren’t reviewed.",
                                    "Check the whole photo and optionally mark missed birds. Add the accepted suggestions and your missed-bird marks together when you’re ready. Existing markers stay in place.",
                                    "You can correct added markers normally. Undo removes the entire added batch; Redo restores it.",
                                    "The detector can miss birds and suggest false or duplicate locations. No suggestions doesn’t mean there are no birds. Review the photo as well as the suggestions."
                                ])
                            } label: { Text("Review and add suggestions").frame(minHeight: 44) }
                            DisclosureGroup {
                                paragraphs([
                                    "Flock Dotter uses a modified CountGD model converted to Core ML, Apple’s on-device model format. It runs on the CPU, the device’s general-purpose processor, using FP32 (32-bit floating-point calculations) and a fixed “bird” prompt.",
                                    "The app scans overlapping crops of your photo and maps predicted locations back onto the original image. Each part of an overlap belongs to one crop, which reduces duplicate acceptance between crops. It doesn’t guarantee unique or correct suggestions.",
                                    "This is experimental bird counting, not species identification. There is no established accuracy or speed guarantee."
                                ])
                            } label: { Text("How detection works").frame(minHeight: 44) }
                            if let notices = Self.notices {
                                DisclosureGroup {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Bundled detector attribution and license text. Available offline.").foregroundStyle(Design.secondary)
                                        Text(notices).font(Design.font(12)).textSelection(.enabled)
                                    }.padding(.top, 12)
                                } label: { Text("Third-party notices").frame(minHeight: 44) }
                            }
                        }
                    } else {
                        section("Bird detection", ["Bird detection is unavailable in this build. You can count birds manually using the controls below."])
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        section("Count and navigate", ["In Count, tap or click each bird to place a marker. Drag to pan without counting, even when starting over a marker. Pinch to zoom. Use Fit to see the whole photo."])
                        DisclosureGroup {
                            paragraphs(["Scroll to pan. Pinch or Option-scroll to zoom. Space-drag and middle-button drag pan in either mode. Use ⌘+ and ⌘− to zoom, and ⌘0 to fit."])
                        } label: { Text("Mac controls").frame(minHeight: 44) }
                    }
                    section("Edit and renumber", ["In Edit, select a marker, then drag it to move or choose Remove. Releasing outside the image cancels a move. On Mac, Delete removes the selection and Escape cancels a move.", "Renumber changes labels only. New markers append to the count. Undo and Redo restore edits."])
                    section("Trace your count", ["Nearest Neighbor starts at the topmost dot, then visits the nearest unvisited dot until every committed dot is numbered. It keeps the total and dot positions. One Undo restores the previous order.", "Connections follow the current labels. Adding, removing or moving a dot updates the lines without running Nearest Neighbor again. Run it again whenever you want a new nearby-dot sequence. Long jumps and crossings can occur.", "Show connections is remembered on this installation. Undo changes the order without hiding connections. With Plain dots, select a dot to read its full number below the photo.", "Annotated PNG captures connections as shown or hidden when Export opens. Numbered dots can clip at photo edges. Use Numbered pins for complete edge labels."])
                    section("Make your marks easier to see", ["Open Marker appearance beside Help. Choose Numbered pins, Plain dots or Numbered dots, then choose a named color. Try a different color when marks blend into the photo.", "Plain dots hide on-photo numbers. Select a dot to read its full number below the photo. Zoom in to separate overlapping marks. Numbered dots keep numbers inside centered circles; longer numbers need larger circles. Badges and numbers can clip at photo edges. Use Numbered pins for complete edge labels.", "Reset to defaults restores Numbered dots and Original. Choices stay on this app installation, including after you clear a workspace. JSON does not carry appearance.", "Annotated PNG records the appearance and count captured when you open Export. Plain dots omit on-photo sequence numbers."])
                    section("Keep or clear a count", ["Recovery keeps one current photo and count on this device. Export JSON with the unchanged original photo to keep an editable count. Reopen Count pairs that JSON with its exact original. Export an annotated image to keep a visual record.", "Open → Clear workspace removes this photo, count and local recovery copy. It always asks first and can’t be undone. Originals and existing exports stay untouched. After clearing succeeds, the app stays empty when reopened until you open another photo or count."])
                    Text("Help is available with or without a photo. Opening it doesn’t run detection.").font(Design.font(12)).foregroundStyle(Design.secondary)
                }.font(Design.font(15)).lineSpacing(5).frame(maxWidth: 590, alignment: .leading).padding(24)
            }.background(Design.surface).accessibilityIdentifier("helpContents").navigationTitle("Help")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(action: done) { Text("Done").frame(minHeight: 44) } } }
        }.font(Design.font()).foregroundStyle(Design.ink).tint(Design.accent).background(Design.surface)
            .instrumentSheet(width: 590, minimumHeight: 400).preferredColorScheme(.light)
    }
    private func paragraphs(_ text: [String]) -> some View {
        VStack(alignment: .leading, spacing: 16) { ForEach(text, id: \.self) { Text($0).fixedSize(horizontal: false, vertical: true) } }.padding(.top, 12)
    }
    private func section(_ title: String, _ text: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Design.font(17, bold: true)).accessibilityAddTraits(.isHeader)
            paragraphs(text)
        }
    }
}

private struct AnchorHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct SupplementHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One direct measurement pass, never nested fitting probes around UIKit/glass.
private struct WorkspaceAnchorLayout: Layout {
    let availableWidth: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rowWidth = sizes.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 8
        if rowWidth <= availableWidth { return CGSize(width: rowWidth, height: sizes.map(\.height).max() ?? 0) }
        return CGSize(width: min(availableWidth, sizes.map(\.width).max() ?? 0), height: sizes.reduce(CGFloat(0)) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * 8)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let row = sizes.reduce(CGFloat(0)) { $0 + $1.width } + CGFloat(max(0, sizes.count - 1)) * 8 <= availableWidth
        var point = bounds.origin
        for (index, subview) in subviews.enumerated() {
            let size = sizes[index]
            subview.place(at: CGPoint(x: point.x, y: row ? bounds.midY - size.height / 2 : point.y), proposal: ProposedViewSize(width: min(size.width, availableWidth), height: size.height))
            if row { point.x += size.width + 8 } else { point.y += size.height + 8 }
        }
    }
}
