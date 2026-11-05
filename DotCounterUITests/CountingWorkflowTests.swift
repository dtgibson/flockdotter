import XCTest

/// Runs the same native workflow on AppKit and UIKit. A unique DEBUG-only recovery
/// session keeps user work separate while retaining the count across test relaunch.
@MainActor final class CountingWorkflowTests: XCTestCase {
    private var app: XCUIApplication!

    private func launchFreshWorkspace() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_FIXTURE"] = "1"
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch()
        XCTAssertTrue(app.staticTexts["QA-flock.jpg"].waitForExistence(timeout: 30), app.debugDescription)
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        expectTotal(0)
    }

    private var canvas: XCUIElement { app.descendants(matching: .any)["countingCanvas"].firstMatch }
    private func point(_ x: Double, _ y: Double) -> XCUICoordinate {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    private func activate(_ element: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), app.debugDescription)
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }
    private func pressPoint(_ x: Double, _ y: Double) {
        #if os(macOS)
        point(x, y).click()
        #else
        point(x, y).tap()
        #endif
    }
    private func control(_ label: String) -> XCUIElement {
        if app.buttons[label].exists { return app.buttons[label].firstMatch }
        #if os(macOS)
        if app.radioButtons[label].exists { return app.radioButtons[label].firstMatch }
        if app.popUpButtons[label].exists { return app.popUpButtons[label].firstMatch }
        if app.menuItems[label].exists { return app.menuItems[label].firstMatch }
        #endif
        return app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    private func expectTotal(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        let total = app.descendants(matching: .any)["countTotal"].firstMatch
        XCTAssertTrue(total.waitForExistence(timeout: 5), file: file, line: line)
        let predicate = NSPredicate(format: "label == %@", "\(count) \(count == 1 ? "bird" : "birds") marked")
        expectation(for: predicate, evaluatedWith: total)
        waitForExpectations(timeout: 5)
    }

    func testCountingEditingNavigationAndRecovery() throws {
        launchFreshWorkspace()
        // Deliberately insert right, left, center so a horizontal renumber changes order.
        pressPoint(0.75, 0.55); expectTotal(1)
        pressPoint(0.25, 0.45); expectTotal(2)
        pressPoint(0.5, 0.5); expectTotal(3)
        activate(control("Undo")); expectTotal(2)
        activate(control("Redo")); expectTotal(3)

        // Identifying a counted bird does not append a duplicate.
        pressPoint(0.75, 0.55); expectTotal(3)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Marker 1")).firstMatch.waitForExistence(timeout: 5))
        activate(control("Edit"))
        activate(control("Remove")); expectTotal(2)
        activate(control("Undo")); expectTotal(3)

        activate(control("Renumber"))
        activate(control("Left to Right"))
        pressPoint(0.75, 0.55)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Marker 3")).firstMatch.waitForExistence(timeout: 5), app.debugDescription)
        expectTotal(3)

        // Count-mode navigation beginning over a marker must never place on release.
        activate(control("Count"))
        point(0.75, 0.55).press(forDuration: 0.1, thenDragTo: point(0.60, 0.40))
        expectTotal(3)
        activate(control("Zoom In")); expectTotal(3)
        activate(control("Zoom Out")); expectTotal(3)
        activate(control("Fit")); expectTotal(3)

        let saved = app.staticTexts["Current count saved on this device"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        let loaded = XCTAttachment(screenshot: app.screenshot())
        loaded.name = "Native count after edit, renumber and navigation"
        loaded.lifetime = .keepAlways
        add(loaded)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["QA-flock.jpg"].waitForExistence(timeout: 30))
        expectTotal(3)
        XCTAssertFalse(control("Undo").isEnabled, "Recovery starts a new in-memory history")
        pressPoint(0.35, 0.50); expectTotal(4)
        let recovered = XCTAttachment(screenshot: app.screenshot())
        recovered.name = "Recovered native workspace and appended marker"
        recovered.lifetime = .keepAlways
        add(recovered)
    }
    #if os(iOS)
    func testRotationAndGeneratedExportPreview() throws {
        launchFreshWorkspace()
        pressPoint(0.5, 0.5); expectTotal(1)
        XCUIDevice.shared.orientation = .landscapeLeft
        expectTotal(1)
        activate(control("Fit"))
        activate(control("Export"))
        let savePNG = control("Save PNG…")
        XCTAssertTrue(savePNG.waitForExistence(timeout: 20), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: savePNG)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed, "Full-size PNG should render before saving")
        let generated = XCTAttachment(screenshot: app.screenshot())
        generated.name = "Actual generated annotated PNG preview in landscape"
        generated.lifetime = .keepAlways
        add(generated)
        activate(control("Editable Count"))
        XCTAssertTrue(app.staticTexts["Keep the marker data and the unchanged original photo together to edit this count later."].waitForExistence(timeout: 5))
        XCTAssertTrue(control("Save JSON…").exists)
        activate(control("Done"))
        expectTotal(1)
        XCUIDevice.shared.orientation = .portrait
        expectTotal(1)
    }
    #endif

    private func captureWorkspaceHelp(_ name: String) {
        let proof = XCTAttachment(screenshot: app.screenshot()); proof.name = name; proof.lifetime = .keepAlways; add(proof)
    }
    private func helpControl(_ label: String) -> XCUIElement {
        let button = control(label), scroll = app.scrollViews["helpContents"]
        for _ in 0..<12 where !button.isHittable {
            let downward = button.frame.minY < scroll.frame.minY + 80
            let from = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.4 : 0.7))
            let to = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: downward ? 0.7 : 0.4))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        XCTAssertTrue(button.isHittable, app.debugDescription)
        return button
    }
    func testClearCancelDurableRelaunchAndOfflineHelp() throws {
        launchFreshWorkspace()
        activate(control("Help"))
        XCTAssertTrue(app.staticTexts["Bird detection · Experimental"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Everything runs on this device. No photo upload, internet connection, account or API key is needed."].exists)
        captureWorkspaceHelp("Native populated Help overview")
        activate(helpControl("How detection works"))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Flock Dotter uses a modified CountGD model converted to Core ML")).firstMatch.exists)
        captureWorkspaceHelp("Native model explanation disclosure")
        activate(helpControl("How detection works"))
        activate(helpControl("Third-party notices"))
        captureWorkspaceHelp("Native offline third-party notices")
        activate(control("Done"))
        activate(control("Open")); activate(control("Clear workspace…"))
        XCTAssertTrue(app.alerts["Clear workspace?"].waitForExistence(timeout: 5))
        captureWorkspaceHelp("Native zero-marker destructive confirmation")
        activate(control("Cancel")); expectTotal(0)
        pressPoint(0.5, 0.5); expectTotal(1)
        activate(control("Open")); activate(control("Clear workspace…"))
        activate(control("Cancel")); expectTotal(1)
        XCTAssertTrue(control("Undo").isEnabled)
        activate(control("Open")); activate(control("Clear workspace…"))
        activate(control("Clear workspace"))
        XCTAssertTrue(app.staticTexts["No photo open"].waitForExistence(timeout: 10))
        expectTotal(0); XCTAssertFalse(control("Undo").isEnabled); XCTAssertFalse(control("Redo").isEnabled)
        captureWorkspaceHelp("Native durable empty workspace")
        app.terminate(); app.launchEnvironment.removeValue(forKey: "DOTCOUNTER_QA_FIXTURE"); app.launch()
        XCTAssertTrue(app.staticTexts["One photo. One count."].waitForExistence(timeout: 15)); expectTotal(0)
        activate(control("Help")); XCTAssertTrue(app.staticTexts["Bird detection · Experimental"].waitForExistence(timeout: 5))
        captureWorkspaceHelp("Native empty-workspace Help after relaunch")
        activate(control("Done"))
    }
    #if os(iOS)
    func testSelectionActionsAreDisabledDuringHeldUncertainClear() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        app.launchEnvironment["DOTCOUNTER_QA_FIXTURE"] = "1"
        app.launchEnvironment["DOTCOUNTER_QA_CLEAR"] = "held-uncertain"
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.staticTexts["QA-flock.jpg"].waitForExistence(timeout: 30))
        pressPoint(0.5, 0.5); expectTotal(1)
        activate(control("Edit")); pressPoint(0.5, 0.5)
        XCTAssertTrue(control("Remove").isEnabled); XCTAssertTrue(control("Deselect marker").isEnabled)
        activate(control("Open")); activate(control("Clear workspace…")); activate(control("Clear workspace"))
        XCTAssertTrue(app.staticTexts["Removing this photo and count from recovery."].waitForExistence(timeout: 5))
        XCTAssertTrue(control("Remove").exists); XCTAssertFalse(control("Remove").isEnabled)
        XCTAssertTrue(control("Deselect marker").exists); XCTAssertFalse(control("Deselect marker").isEnabled)
        captureWorkspaceHelp("Native selected actions disabled during held Clear")
        XCTAssertTrue(app.staticTexts["Couldn’t finish clearing"].waitForExistence(timeout: 20))
        expectTotal(1)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Marker 1")).firstMatch.exists)
        XCTAssertTrue(control("Remove").isEnabled); XCTAssertTrue(control("Deselect marker").isEnabled)
        captureWorkspaceHelp("Native uncertain Clear retained selection and reenabled actions")
    }

    func testHelpAndClearAtAccessibilityXXXL() throws {
        continueAfterFailure = false
        app = XCUIApplication(); app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        app.launchEnvironment["DOTCOUNTER_QA_FIXTURE"] = "1"
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.staticTexts["QA-flock.jpg"].waitForExistence(timeout: 30))
        let bottom = app.scrollViews["workspaceBottomControls"]
        for _ in 0..<4 where !control("Help").isHittable { bottom.swipeUp() }
        XCTAssertTrue(control("Help").isHittable); XCTAssertGreaterThanOrEqual(control("Help").frame.height, 44)
        activate(control("Help")); XCTAssertTrue(control("Done").waitForExistence(timeout: 5))
        captureWorkspaceHelp("Native AX5 Help top and fixed Done")
        let scroll = app.scrollViews["helpContents"]
        for _ in 0..<14 where !app.staticTexts["Keep or clear a count"].isHittable { scroll.swipeUp() }
        XCTAssertTrue(app.staticTexts["Keep or clear a count"].isHittable)
        XCTAssertTrue(control("Done").isHittable); captureWorkspaceHelp("Native AX5 scrolling recovery guidance")
        activate(control("Done"))
        let top = app.scrollViews["workspaceTopControls"]
        for _ in 0..<5 where !control("Open").isHittable { top.swipeUp() }
        activate(control("Open")); activate(control("Clear workspace…"))
        XCTAssertTrue(app.alerts["Clear workspace?"].waitForExistence(timeout: 5))
        captureWorkspaceHelp("Native AX5 clear confirmation")
        let alertScroll = app.alerts["Clear workspace?"].scrollViews.firstMatch
        XCTAssertTrue(alertScroll.exists, "Long confirmation text must scroll at AX5")
        alertScroll.swipeUp(); alertScroll.swipeUp(); alertScroll.swipeUp()
        captureWorkspaceHelp("Native AX5 confirmation scrolled with reachable actions")
        XCTAssertTrue(control("Cancel").isHittable); activate(control("Cancel")); expectTotal(0)
    }
    #endif

}
