#if os(iOS)
import XCTest

@MainActor final class AdaptiveWorkspaceTests: XCTestCase {
    func testNativeWorkspacePhotoNavigationSelectionAndRotation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        app.launchEnvironment["DOTCOUNTER_QA_FIXTURE"] = "1"
        if ProcessInfo.processInfo.environment["ADAPTIVE_LARGE_TEXT"] == "1" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        let canvas = app.descendants(matching: .any)["countingCanvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        let total = app.descendants(matching: .any)["countTotal"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'QA-flock.jpg'"), object: total)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        XCTAssertTrue(app.buttons["Open"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Export"].firstMatch.exists)
        capture(app, "Native workspace — initial geometry")
        // Count in the clear center, then verify that an ordinary navigation drag
        // cannot create a second marker. Source coordinates remain model-owned.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(total.label.contains("1 bird marked"), app.debugDescription)
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.6)))
        XCTAssertTrue(total.label.contains("1 bird marked"))
        capture(app, "Native workspace — counted and panned")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            canvas.frame.width > canvas.frame.height
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        XCTAssertTrue(total.label.contains("1 bird marked"))
        capture(app, "Native workspace — landscape native bars")
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            canvas.frame.height > canvas.frame.width
        }, object: canvas)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed)
        XCTAssertTrue(total.label.contains("1 bird marked"))
    }
    private func capture(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name; image.lifetime = .keepAlways; add(image)
    }
}
#endif

#if os(iOS)
/// Independent Stage 4 input evidence. No app-side viewport hooks are used.
@MainActor final class AdaptiveInputQATests: XCTestCase {
    private var app: XCUIApplication!
    private var canvas: XCUIElement { app.descendants(matching: .any)["countingCanvas"].firstMatch }
    private var total: XCUIElement { app.descendants(matching: .any)["countTotal"].firstMatch }
    private func launch(large: Bool = false, fixture: Bool = true) {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = UUID().uuidString
        if fixture { app.launchEnvironment["DOTCOUNTER_QA_FIXTURE"] = "1" }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        if fixture {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS 'QA-flock.jpg'"), object: total)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 30), .completed)
        }
    }
    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
        let text = XCTAttachment(string: app.debugDescription); text.name = name + " accessibility"; text.lifetime = .keepAlways; add(text)
    }
    private func tap(_ name: String) {
        var button = app.buttons[name].firstMatch
        if !button.exists || !button.isHittable {
            let more = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'more' OR label CONTAINS[c] 'overflow'")).firstMatch
            XCTAssertTrue(more.exists, app.debugDescription); more.tap()
            button = app.buttons[name].firstMatch
        }
        if name == "markerAppearance", !button.exists {
            button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Marker appearance'" )).firstMatch
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
        if !button.isHittable {
            let menu = app.collectionViews.containing(.button, identifier: button.label).firstMatch
            for _ in 0..<6 where !button.isHittable && menu.exists { menu.swipeUp() }
        }
        XCTAssertTrue(button.isHittable, app.debugDescription); button.tap()
    }
    private func drag(_ dx: Double, _ dy: Double) {
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: dx > 0 ? 0.2 : dx < 0 ? 0.8 : 0.5, dy: dy > 0 ? 0.35 : dy < 0 ? 0.75 : 0.55))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: dx > 0 ? 0.8 : dx < 0 ? 0.2 : 0.5, dy: dy > 0 ? 0.75 : dy < 0 ? 0.35 : 0.55))
        from.press(forDuration: 0.1, thenDragTo: to)
    }
    func testEveryEdgeAndCornerProductionPanReleaseBlankRejectionAndFit() {
        launch()
        tap("Fit"); capture("QA input baseline Fit")
        let cases: [(String, Double, Double)] = [("left",1,0),("right",-1,0),("top",0,1),("bottom",0,-1),("top-left",1,1),("top-right",-1,1),("bottom-left",1,-1),("bottom-right",-1,-1)]
        for (name, dx, dy) in cases {
            tap("Fit"); tap("Zoom In")
            for _ in 0..<4 { drag(dx, dy) }
            XCTAssertTrue(total.label.contains("0 birds marked"), "Navigation must not edit")
            capture("QA released pan " + name)
            // A second screenshot is taken after XCTest's next idle boundary.
            capture("QA retained pan " + name)
            canvas.coordinate(withNormalizedOffset: CGVector(dx: dx > 0 ? 0.2 : dx < 0 ? 0.8 : 0.5, dy: dy > 0 ? 0.35 : dy < 0 ? 0.75 : 0.55)).tap()
            XCTAssertTrue(total.label.contains("0 birds marked"), "Blank surround must reject taps: " + name)
            tap("Fit"); capture("QA Fit restored " + name)
        }
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        XCTAssertTrue(total.label.contains("1 bird marked"), "Fit must restore source hit mapping")
        capture("QA post Fit source hit")
    }
    func testNearestNeighborAndIndependentNativeConnectionToggle() {
        launch()
        for x in [0.35, 0.5, 0.65] {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.55)).tap()
        }
        XCTAssertTrue(total.label.contains("3 birds marked"))
        tap("Renumber")
        XCTAssertTrue(app.buttons["Left to Right"].exists); XCTAssertTrue(app.buttons["Top to Bottom"].exists)
        XCTAssertTrue(app.buttons["Nearest Neighbor"].exists)
        capture("Nearest Neighbor native Renumber menu")
        tap("Nearest Neighbor")
        XCTAssertTrue(total.label.contains("3 birds marked"))
        tap("Export")
        XCTAssertTrue(app.staticTexts["Connections shown."].waitForExistence(timeout: 10))
        capture("Nearest Neighbor native captured PNG connections shown")
        tap("Done")
        if !app.descendants(matching: .any)["showConnections"].firstMatch.exists {
            let more = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'more' OR label CONTAINS[c] 'overflow'")).firstMatch
            XCTAssertTrue(more.exists); more.tap()
        }
        let toggle = app.buttons["Show connections"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertTrue(toggle.isHittable)
        XCTAssertTrue(toggle.isSelected)
        capture("Nearest Neighbor native Show connections control")
        toggle.tap()
        tap("Export")
        XCTAssertTrue(app.staticTexts["Connections hidden."].waitForExistence(timeout: 10))
        capture("Nearest Neighbor native captured PNG connections hidden")
        tap("Done")
        XCTAssertTrue(total.label.contains("3 birds marked"))
    }
    func testNativeOverflowSelectionSheetsExportAndRecovery() {
        launch()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55)).tap()
        XCTAssertTrue(total.label.contains("1 bird marked"))
        capture("QA selected workspace")
        tap("markerAppearance")
        XCTAssertTrue(app.buttons["markerStyle-plainDots"].waitForExistence(timeout: 5))
        tap("markerStyle-plainDots"); capture("QA appearance sheet"); tap("Done")
        tap("Help"); XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5)); capture("QA Help sheet"); tap("Done")
        tap("Export")
        let save = app.buttons["Save PNG…"]
        XCTAssertTrue(save.waitForExistence(timeout: 20))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)], timeout: 20), .completed)
        capture("QA generated export sheet"); tap("Done")
        app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS '1 bird marked'"), object: total)], timeout: 30), .completed)
        capture("QA recovered count")
    }
    func testAccessibilityEmptyAndShortLandscape() {
        launch(large: true, fixture: false)
        capture("QA AX5 empty portrait")
        XCTAssertTrue(total.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _,_ in self.canvas.frame.width > self.canvas.frame.height }, object: canvas)], timeout: 10), .completed)
        capture("QA AX5 empty short landscape")
        tap("Help"); XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5)); capture("QA AX5 Help"); tap("Done")
        XCUIDevice.shared.orientation = .portrait
    }
}
#endif
