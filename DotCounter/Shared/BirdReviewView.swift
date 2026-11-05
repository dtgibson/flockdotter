import SwiftUI
import DotCounterCore

struct BirdReviewControls: View {
    @Bindable var workspace:Workspace
    @State private var showList=false
    @Environment(\.dynamicTypeSize) private var textSize
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if let r=workspace.birdReview {
                Text("Reviewed \(r.reviewed) of \(r.suggestions.count)\(r.skipped>0 ? " · ended early":"")").font(Design.font(15,bold:true)).accessibilityIdentifier("birdReviewed")
                Text("\(r.accepted) accepted · \(r.rejected) rejected · \(r.skipped) skipped · \(r.pending) pending").font(Design.font(12)).accessibilityIdentifier("birdTallies")
                if r.skipped>0 {Text("Review ended early; \(r.skipped) skipped, not added.").font(Design.font(12)).foregroundStyle(Design.warning)}
                if r.phase == .guided,let target=workspace.birdCurrent {
                    Text("Suggestion \(r.current+1) of \(r.suggestions.count) · \(r.decisions[r.current].rawValue)").font(Design.font(14,bold:true))
                    if let label=target.nearLabel {Text("Near marker \(label). Accept only if it is a distinct bird.").font(Design.font(12)).foregroundStyle(Design.warning)}
                    (textSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))) {
                        Button("Reject · F"){workspace.decideBird(.rejected,target:target.id,epoch:r.epoch)}.foregroundStyle(Design.destructive).frame(maxWidth:.infinity,minHeight:56).accessibilityIdentifier("birdReject")
                        Button("Accept · J"){workspace.decideBird(.accepted,target:target.id,epoch:r.epoch)}.buttonStyle(InstrumentButtonStyle(primary:true)).frame(maxWidth:.infinity,minHeight:56).accessibilityIdentifier("birdAccept")
                    }.frame(minHeight:56).buttonRepeatBehavior(.disabled)
                    .disabled(workspace.birdTargetReady != r.epoch)
                    Menu {
                        Button("Previous"){workspace.editBirdReview{$0.navigate((r.current+r.suggestions.count-1)%r.suggestions.count)}}
                        Button("Next"){workspace.editBirdReview{$0.navigate((r.current+1)%r.suggestions.count)}}
                        Button("Skip for now"){workspace.editBirdReview{$0.skipForNow()}}
                        Button("Skip all remaining"){workspace.editBirdReview{$0.skipAll()}}.accessibilityIdentifier("birdSkipAll")
                        Button("Suggestion list"){showList=true}
                        if r.pending==0 {Button("Photo check"){workspace.editBirdReview{$0.photoCheck()}}}
                    } label: { Label("Review actions", systemImage: "list.bullet").frame(minHeight: 44) }
                } else if r.phase == .photoCheck {
                    Text("Look for birds without a dot.").font(Design.font(16,bold:true))
                    Text("Suggestions can miss birds. Inspect the photo; draft marks are not saved until Add.").font(Design.font(12))
                    Menu {
                        Button(workspace.birdDraftMode ? "Tap photo to place draft":"Mark a missed bird"){workspace.birdMovingDraft=nil;workspace.birdDraftMode.toggle()}.accessibilityIdentifier("birdDraftMode")
                        Button("Edit draft marks (\(r.drafts.count))"){showList=true}
                        Button("Back to suggestions"){workspace.editBirdReview{$0.navigate(r.current)}}.disabled(r.suggestions.isEmpty)
                    } label: { Label("Review actions", systemImage: "list.bullet").frame(minHeight: 44) }
                    Button("Continue to summary"){workspace.editBirdReview{$0.summary()}}.buttonStyle(InstrumentButtonStyle(primary:true)).frame(minHeight:44).disabled(r.pending>0).accessibilityIdentifier("birdContinue")
                } else {
                    Text("\(r.accepted) accepted suggestions + \(r.drafts.count) draft manual marks").font(Design.font(15,bold:true))
                    Text("Your count is still \(workspace.total). Only accepted suggestions and your draft marks will be added.").font(Design.font(12))
                    (textSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout())) {
                        Button("Back to photo check"){workspace.editBirdReview{$0.photoCheck()}}
                        Button("Add \(r.accepted+r.drafts.count) markers"){workspace.applyBirds()}.buttonStyle(InstrumentButtonStyle(primary:true)).disabled(!workspace.canApplyBirds).accessibilityIdentifier("birdApply")
                    }.frame(minHeight:44)
                    if !r.eligible {Text("Recorded review fixture. Apply is unavailable; this is not a live complete scan.").font(Design.font(12))}
                }
                Menu {
                    if r.canUndo {Button(r.undoIsBulk ? "Undo skip all":"Undo decision"){workspace.editBirdReview{$0.undo()}}.accessibilityIdentifier("birdReviewUndo")}
                    Button(workspace.birdShowOthers ? "Hide suggestions":"Show suggestions"){workspace.birdShowOthers.toggle()}
                    Button("Discard review"){workspace.invalidateBirdDetection()}.accessibilityIdentifier("birdDiscard")
                } label: { Label("Review actions", systemImage: "list.bullet").frame(minHeight: 44) }
            } else if workspace.birdOwner {
                HStack {if workspace.birdKey != nil {ProgressView().controlSize(.small)};Text(progressLabel).font(Design.font(13));Spacer();if workspace.birdKey != nil {Button("Cancel detection"){workspace.invalidateBirdDetection(message:"Detection canceled. Your count is unchanged.")}.frame(minHeight:44).accessibilityIdentifier("birdCancel")}}
            } else if !workspace.birdMessage.isEmpty {Text(workspace.birdMessage).font(Design.font(12)).foregroundStyle(workspace.birdActivity == .failed ? Design.warning:Design.secondary)}
        }.padding(.horizontal,16).padding(.vertical,8).frame(maxWidth:.infinity,alignment:.leading).background(Design.surface)
        .sheet(isPresented:$showList){reviewList}
    }
    private var progressLabel:String {
        if workspace.birdKey==nil{return "Finishing canceled scan…"}
        if case let .running(done,total)=workspace.birdActivity{return "\(done) of \(total) areas processed"}
        return "Preparing local detection…"
    }
    private var reviewList:some View {
        NavigationStack {List {
            if let r=workspace.birdReview {
                Section("Suggestions") {ForEach(Array(r.suggestions.enumerated()),id:\.element.id){i,item in
                    Button("Suggestion \(i+1) · \(r.decisions[i].rawValue)\(item.nearLabel.map{" · near marker \($0)"} ?? "")"){workspace.editBirdReview{$0.navigate(i)};showList=false}
                }}
                Section("Draft manual additions") {ForEach(Array(r.drafts.enumerated()),id:\.element.id){i,draft in
                    HStack {Text("Draft \(i+1)");Button("Move"){workspace.birdMovingDraft=draft.id;workspace.birdDraftMode=true;showList=false};Button("Remove"){workspace.editBirdReview{$0.removeDraft(draft.id)}}}
                }}
            }
        }.scrollContentBackground(.hidden).background(Design.surface).navigationTitle("Review suggestions").toolbar{ToolbarItem(placement:.confirmationAction){Button("Done"){showList=false}}}}
        .font(Design.font()).foregroundStyle(Design.ink).tint(Design.accent)
        .instrumentSheet(width: 500, minimumHeight: 360).preferredColorScheme(.light)
    }
}
