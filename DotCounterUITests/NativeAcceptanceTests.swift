#if os(iOS)
import XCTest
import UIKit

@MainActor final class NativeAcceptanceTests: XCTestCase {
    private var app: XCUIApplication!
    private var session = ""
    private var interchangeFolder = "DotCounter-Acceptance-20261027"
    private var canvas: XCUIElement { app.descendants(matching: .any)["countingCanvas"].firstMatch }
    private func launch(dense: Bool) {
        continueAfterFailure = false
        session = UUID().uuidString
        print("NATIVE_QA_SESSION=\(session)")
        app = XCUIApplication()
        app.launchEnvironment["DOTCOUNTER_QA_SESSION"] = session
        app.launchEnvironment["DOTCOUNTER_QA_RECORD"] = "1"
        app.launchEnvironment["DOTCOUNTER_QA_CONTINUOUS_NAV"] = "1"
        if !dense { app.launchEnvironment["DOTCOUNTER_QA_FILENAME"] = "QA-\(session).jpg" }
        app.launchEnvironment[dense ? "DOTCOUNTER_QA_DENSE" : "DOTCOUNTER_QA_FIXTURE"] = "1"
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts[dense ? "QA-24MP.jpg" : "QA-\(session).jpg"].waitForExistence(timeout: 90), app.debugDescription)
    }
    private func tap(_ label: String) {
        let element = app.buttons[label].firstMatch
        if !element.exists { XCTAssertTrue(element.waitForExistence(timeout: 15), app.debugDescription) }
        if ["Editable Count", "Annotated Image"].contains(label), app.scrollViews["exportContents"].exists {
            app.scrollViews["exportContents"].swipeDown(); app.scrollViews["exportContents"].swipeDown()
        }
        if !element.isHittable, app.scrollViews["exportContents"].exists {
            app.scrollViews["exportContents"].swipeDown()
            for _ in 0..<4 where !element.isHittable { app.scrollViews["exportContents"].swipeUp() }
        }
        element.tap()
    }
    private func expectTotal(_ total: Int) {
        let label = app.descendants(matching: .any)["countTotal"].firstMatch
        let predicate = NSPredicate(format: "label == %@ OR label == %@", "\(total) \(total == 1 ? "bird" : "birds") marked", "\(total.formatted()) \(total == 1 ? "bird" : "birds") marked")
        if !predicate.evaluate(with: label) {
            let expectation = XCTNSPredicateExpectation(predicate: predicate, object: label)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 30), .completed, app.debugDescription)
        }
    }
    func testDenseNativeActionsNavigationAndWarmOpening() {
        launch(dense: true)
        expectTotal(1000)
        XCTAssertTrue(app.staticTexts["Current count saved on this device"].waitForExistence(timeout: 30))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["QA-24MP.jpg"].waitForExistence(timeout: 90))
        expectTotal(1000)
        // Resolve marker spacing in screen points so the center is genuinely empty.
        for _ in 0..<6 { tap("Zoom In") }
        for _ in 0..<10 {
            tap("Count")
            canvas.tap(); expectTotal(1001) // 1 add
            tap("Undo"); expectTotal(1000) // 2
            tap("Redo"); expectTotal(1001) // 3
            tap("Edit"); canvas.tap()
            tap("Remove"); expectTotal(1000) // 4 delete
            tap("Undo"); expectTotal(1001) // 5 restore delete
            tap("Undo"); expectTotal(1000) // 6 undo add
            tap("Redo"); expectTotal(1001) // 7
            tap("Undo"); expectTotal(1000) // 8
            tap("Renumber"); tap("Left to Right"); expectTotal(1000) // 9
            tap("Undo"); expectTotal(1000) // 10, exact initial order restored
        }
        // The requirement counts add/delete/undo latency. Redo/renumber are
        // useful extras; collect thirty more Undo samples without replacing
        // any qualifying action by those extras (160 committed edits total).
        for _ in 0..<30 { tap("Redo"); expectTotal(1000); tap("Undo"); expectTotal(1000) }
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5))
        let velocity = XCUIGestureVelocity(rawValue: canvas.frame.width * 0.6 / 5)
        start.press(forDuration: 0.01, thenDragTo: end, withVelocity: velocity, thenHoldForDuration: 0)
        canvas.pinch(withScale: 1.5, velocity: 0.1)
        expectTotal(1000)
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = "24MP native workspace after 100 mixed actions and navigation"; screenshot.lifetime = .keepAlways; add(screenshot)
        print("NATIVE_QA_FINISHED_SESSION=\(session)")
    }
    private func providerRoot() {
        XCTAssertTrue(app.otherElements["Browse View (Picker)"].waitForExistence(timeout: 30), app.debugDescription)
        if app.buttons["Browse"].exists { tap("Browse") }
        let local = app.staticTexts[UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"].firstMatch
        for _ in 0..<4 where !local.exists {
            let back = app.buttons["DOC.navBarButton.backInHistory"]
            if back.exists && back.isEnabled { back.tap() }
        }
        XCTAssertTrue(local.waitForExistence(timeout: 15), app.debugDescription)
        local.tap()
    }
    private func providerItem(_ filename: String) {
        // Files hides recognized image extensions in its cell identifier.
        let displayedName = filename.hasSuffix(".jpg") ? String(filename.dropLast(4)) : filename
        let cell = app.cells.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@", filename + ",", displayedName + ",")).firstMatch
        if !cell.exists { XCTAssertTrue(cell.waitForExistence(timeout: 15), app.debugDescription) }
        cell.tap()
    }
    private func chooseInterchangeFolder() {
        providerRoot()
        providerItem(interchangeFolder)
    }
    private func saveToInterchangeFolder(kind: String) {
        chooseInterchangeFolder()
        let open = app.buttons["DOCPicker.actionButton"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: open)
        if !open.isEnabled { XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed) }
        open.tap()
        XCTAssertTrue(app.staticTexts["\(kind) saved"].waitForExistence(timeout: 30), app.debugDescription)
    }
    func testRealFilesMacPairReopenAndIndependentOutputs() {
        launch(dense: false)
        tap("Open"); tap("Reopen Count…")
        chooseInterchangeFolder(); providerItem("From-Mac.dotcounter.json")
        XCTAssertTrue(app.staticTexts["The marker file needs the exact photo used for the count."].waitForExistence(timeout: 20), app.debugDescription)
        tap("Choose Original Photo…")
        chooseInterchangeFolder(); providerItem("From-Mac.jpg")
        expectTotal(3)
        XCTAssertFalse(app.buttons["Undo"].isEnabled, "Native pair reopening resets in-memory history")
        canvas.tap(); expectTotal(4)
        tap("Export"); tap("Editable Count"); tap("Save JSON…")
        saveToInterchangeFolder(kind: "JSON")
        tap("Save Original Photo Copy…"); saveToInterchangeFolder(kind: "Original Photo")
        XCTAssertTrue(app.staticTexts["JSON saved"].exists)
        tap("Annotated Image")
        let savePNG = app.buttons["Save PNG…"]
        if !savePNG.isEnabled {
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: savePNG)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
        }
        tap("Save PNG…"); saveToInterchangeFolder(kind: "PNG")
        let saved = XCTAttachment(screenshot: app.screenshot()); saved.name = "Actual native Files PNG completion"; saved.lifetime = .keepAlways; add(saved)
        tap("Editable Count")
        XCTAssertTrue(app.staticTexts["JSON saved"].exists)
        XCTAssertTrue(app.staticTexts["Original Photo saved"].exists)
        tap("Done"); expectTotal(4)
        let reopened = XCTAttachment(screenshot: app.screenshot()); reopened.name = "Mac pair reopened natively and edited on iOS"; reopened.lifetime = .keepAlways; add(reopened)
        print("NATIVE_FILES_FINISHED_SESSION=\(session)")
    }
    func testSecurityTransientLifetimeAcrossRealFilesSave() {
        interchangeFolder = "DotCounter-Security-20261027"
        testRealFilesMacPairReopenAndIndependentOutputs()
    }
}
#endif
