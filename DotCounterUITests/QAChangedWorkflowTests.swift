#if os(iOS)
import XCTest

@MainActor final class QAChangedWorkflowTests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(provider: String? = nil, enlarged: Bool = false) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        app.launchEnvironment["DOTCOUNTER_QA_FIXTURE"] = "1"
        app.launchEnvironment["DOTCOUNTER_QA_PROVIDER_OUTCOME"] = provider
        if enlarged { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["QA-flock.jpg"].waitForExistence(timeout: 30))
    }
    private func tap(_ label: String) {
        let button = app.buttons[label].firstMatch
        if ["Editable Count", "Annotated Image"].contains(label), app.scrollViews["exportContents"].exists {
            // A partially occluded segment can still report hittable under the
            // navigation bar. Restore the scroll top before changing tabs.
            app.scrollViews["exportContents"].swipeDown()
            app.scrollViews["exportContents"].swipeDown()
        }
        XCTAssertTrue(button.waitForExistence(timeout: 10), app.debugDescription)
        if !button.isHittable, app.scrollViews["exportContents"].exists {
            let contents = app.scrollViews["exportContents"]
            contents.swipeDown()
            for _ in 0..<4 where !button.isHittable { contents.swipeUp() }
        }
        XCTAssertTrue(button.isHittable, app.debugDescription)
        button.tap()
    }
    private func readyPNG() {
        let save = app.buttons["Save PNG…"]
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
    }
    func testOpenMenuPresentsPhotosFromEmptyAndLoadedWorkspace() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["One photo. One count."].waitForExistence(timeout: 15))
        // The empty-state and source-header menus must both present from the
        // workspace host, survive cancellation, and present again.
        let headerOpen = app.buttons["Open"]
        let photoOpen = app.buttons["Open Photo"]
        XCTAssertTrue(headerOpen.exists && photoOpen.exists, app.debugDescription)
        for button in [photoOpen, headerOpen, photoOpen] {
            button.tap()
            tap("Choose from Photos…")
            cancelPhotos()
            XCTAssertTrue(app.staticTexts["One photo. One count."].exists)
        }
        app.terminate()
        launch()
        for _ in 0..<2 {
            tap("Open")
            tap("Choose from Photos…")
            cancelPhotos()
            XCTAssertTrue(app.staticTexts["QA-flock.jpg"].exists)
        }
    }
    private func cancelPhotos() {
        // This is the system PhotosUI sheet reached through the real menu,
        // not a test presenter or a substitute imported fixture.
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 15), app.debugDescription)
        let proof = XCTAttachment(screenshot: app.screenshot())
        proof.name = "System Photos picker reached from Open menu"
        proof.lifetime = .keepAlways
        add(proof)
        cancel.tap()
        XCTAssertTrue(cancel.waitForNonExistence(timeout: 5))
    }
    func testProviderFailureShowsSpecificErrorAndRetryForAllThreeOutputs() {
        launch(provider: "failure")
        tap("Export"); readyPNG(); tap("Save PNG…")
        assertFailure("PNG")
        tap("Retry PNG…"); assertFailure("PNG")
        tap("Editable Count")
        tap("Save JSON…"); assertFailure("JSON")
        tap("Save Original Photo Copy…"); assertFailure("Original Photo")
        XCTAssertFalse(app.staticTexts["JSON saved"].exists)
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "Output-specific provider failure and retry"; proof.lifetime = .keepAlways; add(proof)
        tap("Done")
        XCTAssertTrue(app.descendants(matching: .any)["countTotal"].firstMatch.label.contains("0 birds marked"))
    }
    private func assertFailure(_ kind: String) {
        let error = app.staticTexts["exportOutputError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(error.label.contains("\(kind) could not be saved"), error.label)
        XCTAssertTrue(error.label.contains("Destination provider unavailable"))
        XCTAssertTrue(app.buttons["Retry \(kind)…"].exists)
    }
    func testProviderCancellationIsQuietForAllThreeOutputs() {
        launch(provider: "cancel")
        tap("Export"); readyPNG(); tap("Save PNG…")
        XCTAssertFalse(app.staticTexts["exportOutputError"].exists)
        XCTAssertFalse(app.staticTexts["PNG saved"].exists)
        tap("Editable Count"); tap("Save JSON…")
        XCTAssertFalse(app.staticTexts["exportOutputError"].exists)
        XCTAssertFalse(app.staticTexts["JSON saved"].exists)
        tap("Save Original Photo Copy…")
        XCTAssertFalse(app.staticTexts["exportOutputError"].exists)
        XCTAssertFalse(app.staticTexts["Original Photo saved"].exists)
        tap("Done")
    }
    // Small directional drags keep a target from jumping past the viewport
    // when large text makes the top region several screens tall.
    private func reveal(_ button: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<10 where !button.isHittable {
            let targetAbove = button.frame.midY < scroll.frame.minY + 80
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: targetAbove ? 0.45 : 0.65))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: targetAbove ? 0.65 : 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }
    func testAccessibilityXXXLControlsAreReachableWithoutOverlappingCanvas() {
        launch(enlarged: true)
        let canvas = app.descendants(matching: .any)["countingCanvas"].firstMatch
        XCTAssertTrue(canvas.isHittable)
        XCTAssertGreaterThan(canvas.frame.height, 100)
        canvas.tap()
        let top = app.scrollViews["workspaceTopControls"]
        XCTAssertTrue(top.exists, app.debugDescription)
        reveal(app.buttons["Edit"], in: top)
        tap("Edit")
        XCTAssertTrue(app.buttons["Count"].isHittable)
        reveal(app.buttons["Undo"], in: top)
        XCTAssertTrue(app.buttons["Undo"].isHittable)
        XCTAssertTrue(app.buttons["Redo"].isHittable)
        canvas.tap()
        let bottom = app.scrollViews["workspaceBottomControls"]
        reveal(app.buttons["Remove"], in: bottom)
        tap("Remove")
        reveal(app.buttons["Fit"], in: bottom)
        tap("Fit")
        XCTAssertTrue(app.buttons["Zoom In"].isHittable)
        XCTAssertTrue(app.buttons["Zoom Out"].isHittable)
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = "Native accessibility XXXL controls and canvas"; proof.lifetime = .keepAlways; add(proof)
    }
}
#endif

#if os(iOS)
/// Dot appearance QA: real native presentation/actions, isolated from owner work.
@MainActor final class DotAppearanceWorkflowQATests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(large: Bool = false, fixture: Bool = true) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        if fixture { app.launchEnvironment["DOTCOUNTER_QA_FIXTURE"] = "1" }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["markerAppearance"].waitForExistence(timeout: 30))
    }
    private func capture(_ name: String) {
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = name; proof.lifetime = .keepAlways; add(proof)
    }
    private func readable(_ button: XCUIElement, in scroll: XCUIElement) -> Bool {
        let viewport = app.frame.intersection(scroll.frame)
        let overlap = viewport.intersection(button.frame)
        return button.isHittable && overlap.height >= min(button.frame.height, viewport.height) - 1
            && overlap.width >= min(button.frame.width, viewport.width) - 1
    }
    private var workspaceControlHost: XCUIElement {
        let unified = app.scrollViews["emptyWorkspaceContents"]
        return unified.exists && unified.buttons["markerAppearance"].exists ? unified : app.scrollViews["workspaceBottomControls"]
    }
    private func reveal(_ button: XCUIElement, in scroll: XCUIElement) {
        for _ in 0..<24 where !readable(button, in: scroll) {
            let above = button.frame.midY < scroll.frame.midY
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: above ? 0.4 : 0.7))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: above ? 0.7 : 0.4)))
        }
        XCTAssertTrue(readable(button, in: scroll), app.debugDescription)
    }
    private func choose(_ identifier: String) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        let contents = app.scrollViews.containing(.button, identifier: "markerStyle-numberedDots").firstMatch
        if !readable(button, in: contents) { reveal(button, in: contents) }
        XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        button.tap()
        XCTAssertTrue(button.isSelected, "Named native selection trait must follow the chosen value")
    }
    private func openAppearance() {
        let entry = app.buttons["markerAppearance"]
        let host = workspaceControlHost
        if host.exists { reveal(entry, in: host) } else { XCTAssertTrue(entry.isHittable) }
        entry.tap()
        XCTAssertTrue(app.buttons["markerStyle-numberedDots"].waitForExistence(timeout: 5))
    }
    func testRealSheetSelectionsRecoveryResetClearAndPreview() {
        launch()
        let canvas = app.descendants(matching: .any)["countingCanvas"].firstMatch
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Marker 1")).firstMatch.waitForExistence(timeout: 5))
        openAppearance()
        XCTAssertTrue(app.buttons["markerStyle-numberedDots"].isSelected)
        XCTAssertTrue(app.buttons["markerColor-legacy"].isSelected)
        for style in ["numberedPins", "plainDots", "numberedDots"] {
            choose("markerStyle-" + style)
            for color in ["legacy", "white", "yellow", "coral", "cyan"] { choose("markerColor-" + color) }
            XCTAssertTrue(app.buttons["markerStyle-" + style].isSelected)
        }
        choose("markerStyle-plainDots"); choose("markerColor-yellow")
        capture("Real native settings sheet selected Plain dots Yellow")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["markerAppearance"].label.contains("Plain dots, Yellow"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Marker 1")).firstMatch.exists)
        app.buttons["Export"].tap()
        XCTAssertTrue(app.staticTexts["1 markers · Plain dots · Yellow"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["On-photo sequence numbers are omitted. Selection outlines are not exported."].exists)
        let save = app.buttons["Save PNG…"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        capture("Real plain dot generated PNG sheet")
        app.buttons["Done"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["markerAppearance"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.buttons["markerAppearance"].label.contains("Plain dots, Yellow"))
        app.buttons["Open"].tap(); app.buttons["Clear workspace…"].tap(); app.buttons["Clear workspace"].tap()
        XCTAssertTrue(app.staticTexts["No photo open"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["markerAppearance"].label.contains("Plain dots, Yellow"))
        openAppearance()
        let reset = app.buttons["resetMarkerAppearance"]
        if !reset.isHittable { reveal(reset, in: app.scrollViews.containing(.button, identifier: "markerStyle-numberedDots").firstMatch) }
        reset.tap()
        XCTAssertFalse(reset.isEnabled)
        XCTAssertTrue(app.buttons["markerStyle-numberedDots"].isSelected)
        XCTAssertTrue(app.buttons["markerColor-legacy"].isSelected)
        capture("Real empty workspace appearance reset")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["markerAppearance"].label.contains("Numbered dots, Original"))
    }
    func testMaximumTextRealEmptySheetAndLandscapeReachability() {
        launch(large: true, fixture: false)
        openAppearance()
        choose("markerStyle-plainDots"); choose("markerColor-cyan")
        let reset = app.buttons["resetMarkerAppearance"]
        reveal(reset, in: app.scrollViews.containing(.button, identifier: "markerStyle-numberedDots").firstMatch)
        capture("Real AX5 settings reset and local retention guidance")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        reset.tap(); app.buttons["Done"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in self.app.frame.width > self.app.frame.height }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        openAppearance()
        choose("markerStyle-numberedPins"); choose("markerColor-coral")
        capture("Real AX5 landscape native appearance sheet")
        XCTAssertTrue(app.buttons["Done"].isHittable)
        app.buttons["Done"].tap()
        let bottom = workspaceControlHost
        let help = app.buttons["Help"]
        reveal(help, in: bottom)
        XCTAssertGreaterThanOrEqual(app.frame.intersection(bottom.frame).intersection(help.frame).height, 44)
        capture("Resolved AX5 landscape empty workspace reachable Help")
        help.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        app.buttons["Done"].tap()
        let contents = app.scrollViews["emptyWorkspaceContents"]
        XCTAssertTrue(contents.exists)
        for name in ["Open Photo", "Reopen Count"] {
            let button = app.buttons[name]
            reveal(button, in: contents)
            XCTAssertGreaterThanOrEqual(app.frame.intersection(contents.frame).intersection(button.frame).height, 44)
        }
        capture("Resolved AX5 landscape empty content scroll and Reopen Count")
        XCUIDevice.shared.orientation = .portrait
    }
}
#endif
